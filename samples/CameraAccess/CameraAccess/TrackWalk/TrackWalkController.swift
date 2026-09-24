import AVFoundation
import QuartzCore
import SwiftUI

/// Runs one Track Walk: preflight, audio session, recorder, cues, pause/resume,
/// limits and glasses events. After Stop, the finisher takes over.
@MainActor
final class TrackWalkController: ObservableObject {
  enum Phase: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case finishing
  }

  enum FinishReason {
    case user
    case timeLimit
    case storageFull
    case pausedTooLong
    case glassesStopped
    case leftScreen
  }

  @Published private(set) var phase: Phase = .idle
  @Published private(set) var elapsed: TimeInterval = 0
  @Published private(set) var sessionTrack = ""
  @Published var errorMessage: String?

  var isActive: Bool { phase != .idle }
  /// The glasses link should stay up (a fold must reconnect so unfolding resumes).
  /// Not while finishing: a deliberate stop must let the link wind down.
  var keepsGlassesAlive: Bool { phase == .preparing || phase == .recording || phase == .paused }
  private(set) var isPausedByFold = false

  private var recorder: TrackWalkRecorder?
  private var captureId: UUID?
  private var frameSubscription: UUID?
  private var unsubscribeFrames: ((UUID) -> Void)?
  private var ticker: Task<Void, Never>?
  private var stopGrace: Task<Void, Never>?
  private var warned = false
  private var pausedSince: TimeInterval?

  // MARK: - Start

  func begin(
    session: ScoutSessionSummary,
    subscribeFrames: (@escaping (VideoFrameSample) -> Void) -> UUID,
    unsubscribeFrames: @escaping (UUID) -> Void,
    glassesSource: Bool
  ) async {
    guard phase == .idle else { return }
    phase = .preparing
    errorMessage = nil
    sessionTrack = session.track

    if let free = TrackWalkMedia.freeBytes(), free < TrackWalkLimits.minFreeBytesToStart {
      fail("A Track Walk needs 3 GB free. Free up space and try again.")
      return
    }
    // Download the speech model now, while online; recording goes ahead either way.
    _ = await TrackWalkMedia.ensureSpeechModel()

    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetooth, .defaultToSpeaker])
      try audio.setActive(true)
      if glassesSource { GlassesAudioRoute.selectGlassesMicIfNeeded() }
    } catch {
      fail("Audio could not start: \(error.localizedDescription)")
      return
    }

    let id = UUID()
    let recorder = TrackWalkRecorder(outputURL: TrackWalkMedia.url(for: id, ext: "mov"))
    do {
      try recorder.start()
    } catch {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      fail("The microphone could not start.")
      return
    }
    let capture = Capture(
      id: id, mode: .trackWalk, sessionId: session.id, trackName: session.track,
      transcript: [], scoutContext: "Track Walk", vehicleModel: "", durationMin: 0,
      state: .recording, videoFileName: TrackWalkMedia.url(for: id, ext: "mov").lastPathComponent)
    // On disk before the first frame is written (the .mov is created on the
    // first video frame, after the subscription below), so a crash is recoverable.
    ScoutOutbox.shared.add(capture)
    TrackWalkFinisher.shared.liveCaptureId = id
    self.recorder = recorder
    self.captureId = id
    self.unsubscribeFrames = unsubscribeFrames
    frameSubscription = subscribeFrames { [weak recorder] frame in
      recorder?.appendVideo(frame.pixelBuffer, hostTime: CACurrentMediaTime())
    }
    warned = false
    isPausedByFold = false
    pausedSince = nil
    elapsed = 0
    phase = .recording
    SpokenCues.shared.speak("Recording started")
    startTicker()
  }

  // MARK: - Controls

  func pauseByUser() { pause(byFold: false) }

  func resumeByUser() { resume() }

  func glassesFolded() {
    stopGrace?.cancel()
    stopGrace = nil
    guard phase == .recording else { return }
    pause(byFold: true)
  }

  func glassesUnfolded() {
    guard phase == .paused, isPausedByFold else { return }
    resume()
  }

  /// The glasses stream stopped. A fold reports hingesClosed around the same
  /// moment; if none arrives within 1 s, it was a tap-and-hold or a drop, and
  /// the walk finishes (spec §B4: a drop can't be told from a tap-and-hold).
  func glassesStreamStopped() {
    guard phase == .recording, stopGrace == nil else { return }
    stopGrace = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.stopGrace = nil
      guard self.phase == .recording else { return }
      await self.finish(reason: .glassesStopped)
    }
  }

  private func pause(byFold: Bool) {
    guard phase == .recording, let recorder else { return }
    recorder.pause(at: CACurrentMediaTime())
    isPausedByFold = byFold
    pausedSince = CACurrentMediaTime()
    phase = .paused
    SpokenCues.shared.speak("Paused")
  }

  private func resume() {
    guard phase == .paused, let recorder else { return }
    recorder.resume(at: CACurrentMediaTime())
    isPausedByFold = false
    pausedSince = nil
    phase = .recording
    SpokenCues.shared.speak("Recording")
  }

  // MARK: - Stop

  func finish(reason: FinishReason) async {
    guard phase == .recording || phase == .paused, let recorder, let id = captureId else { return }
    phase = .finishing
    ticker?.cancel()
    ticker = nil
    stopGrace?.cancel()
    stopGrace = nil
    if let frameSubscription { unsubscribeFrames?(frameSubscription) }
    frameSubscription = nil

    let recorded = recorder.elapsed(at: CACurrentMediaTime())
    let wrote = await recorder.finish()
    ScoutOutbox.shared.update(id) { $0.durationMin = max(1, Int((recorded / 60).rounded())) }
    SpokenCues.shared.speak(reason == .storageFull ? "Storage full, saved" : "Stopped")
    NSLog("[TrackWalk] Finished (%@), %.0f s, file written: %@", String(describing: reason), recorded, wrote ? "yes" : "no")

    self.recorder = nil
    captureId = nil
    isPausedByFold = false
    TrackWalkFinisher.shared.liveCaptureId = nil
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    phase = .idle
    // A fresh task: it must not inherit the caller's cancellation (an automatic stop runs inside the ticker being cancelled).
    Task { await TrackWalkFinisher.shared.advance(id) }
  }

  // MARK: - Limits

  private func startTicker() {
    ticker?.cancel()
    ticker = Task { @MainActor [weak self] in
      var tick = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard let self, !Task.isCancelled, let recorder = self.recorder else { return }
        tick += 1
        let now = CACurrentMediaTime()
        self.elapsed = recorder.elapsed(at: now)
        switch TrackWalkLimits.cue(elapsed: self.elapsed, warned: self.warned) {
        case .none: break
        case .twoMinutesLeft:
          self.warned = true
          SpokenCues.shared.speak("Two minutes left")
        case .stop:
          await self.finish(reason: .timeLimit)
          return
        }
        if let since = self.pausedSince, now - since >= TrackWalkLimits.pausedFinishAfter {
          await self.finish(reason: .pausedTooLong)
          return
        }
        if tick % 30 == 0, let free = TrackWalkMedia.freeBytes(),
           free < TrackWalkLimits.minFreeBytesWhileRecording {
          await self.finish(reason: .storageFull)
          return
        }
      }
    }
  }

  private func fail(_ message: String) {
    errorMessage = message
    phase = .idle
  }
}
