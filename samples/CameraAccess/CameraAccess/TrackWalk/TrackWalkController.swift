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
    case recordingFailed
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
  /// What the view model does once the stop grace resolves (reconnect or wind down the link).
  private var pendingStreamStop: (() -> Void)?
  /// Stop pressed (or the screen left) while still preparing; `begin` backs out.
  private var cancelRequested = false
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
    cancelRequested = false
    errorMessage = nil
    sessionTrack = session.track

    if let free = TrackWalkMedia.freeBytes(), free < TrackWalkLimits.minFreeBytesToStart {
      fail("A Track Walk needs 3 GB free. Free up space and try again.")
      return
    }
    // Download the speech model while online, without holding up the recording;
    // the finisher checks for it again before transcribing.
    Task.detached(priority: .utility) { _ = await TrackWalkMedia.ensureSpeechModel() }

    do {
      let audio = AVAudioSession.sharedInstance()
      try audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.allowBluetooth, .defaultToSpeaker])
      try audio.setActive(true)
      if glassesSource { GlassesAudioRoute.selectGlassesMicIfNeeded() }
    } catch {
      fail("Audio could not start: \(error.localizedDescription)")
      return
    }
    guard !cancelRequested else { cancelPreparing(recorder: nil); return }

    let id = UUID()
    let recorder = TrackWalkRecorder(outputURL: TrackWalkMedia.url(for: id, ext: "mov"))
    recorder.onFailure = { [weak self] _ in
      Task { @MainActor in
        guard let self, self.phase == .recording || self.phase == .paused else { return }
        SpokenCues.shared.speak("Recording failed")
        await self.finish(reason: .recordingFailed)
      }
    }
    do {
      try recorder.start()
    } catch {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      fail("The microphone could not start.")
      return
    }
    guard !cancelRequested else { cancelPreparing(recorder: recorder); return }
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
    let proceed = pendingStreamStop
    pendingStreamStop = nil
    if phase == .recording { pause(byFold: true) }
    // The stream stop that started the grace was this fold: let the link reconnect.
    proceed?()
  }

  func glassesUnfolded() {
    guard phase == .paused, isPausedByFold else { return }
    resume()
  }

  /// The glasses stream stopped. A fold reports hingesClosed around the same
  /// moment; if none arrives within 1 s, it was a tap-and-hold or a drop, and
  /// the walk finishes (spec §B4: a drop can't be told from a tap-and-hold).
  /// `proceed` is the caller's handling of the stop (reconnect or wind down);
  /// it runs once the grace resolves, so the glasses link (and its error
  /// listener) stays up long enough for a late hingesClosed to arrive.
  func glassesStreamStopped(then proceed: @escaping () -> Void) {
    if stopGrace != nil { return }  // A grace is already running; it will proceed.
    guard phase == .recording else { proceed(); return }
    pendingStreamStop = proceed
    stopGrace = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1))
      guard let self, !Task.isCancelled else { return }
      self.stopGrace = nil
      let proceed = self.pendingStreamStop
      self.pendingStreamStop = nil
      if self.phase == .recording {
        await self.finish(reason: .glassesStopped)
      }
      proceed?()
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
    if phase == .preparing {
      cancelRequested = true
      return
    }
    guard phase == .recording || phase == .paused, let recorder, let id = captureId else { return }
    phase = .finishing
    ticker?.cancel()
    ticker = nil
    stopGrace?.cancel()
    stopGrace = nil
    // A stream stop still in its grace: hand it back once the walk is idle, so the link winds down.
    let pendingStop = pendingStreamStop
    pendingStreamStop = nil
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
    // The audio session stays active so the final cue is not cut off; the next
    // Race start reconfigures it (AudioManager).
    phase = .idle
    pendingStop?()
    // A fresh task: it must not inherit the caller's cancellation (an automatic stop runs inside the ticker being cancelled).
    Task { await TrackWalkFinisher.shared.advance(id) }
  }

  /// Backs out of a start that was cancelled while preparing: nothing is saved.
  private func cancelPreparing(recorder: TrackWalkRecorder?) {
    NSLog("[TrackWalk] Start cancelled while preparing")
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    if let recorder {
      recorder.onFailure = nil
      Task { _ = await recorder.finish() }
    }
    cancelRequested = false
    phase = .idle
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
