import AVFoundation
import Foundation

/// Takes a stopped (or crashed) Track Walk from its .mov to a queued report:
/// remux to .mp4 → Photos → transcribe → reportPending. Every step records its
/// result in the Outbox before the next one runs, so it can pick up where it
/// left off after a relaunch.
@MainActor
final class TrackWalkFinisher {
  static let shared = TrackWalkFinisher()

  /// The capture being recorded right now; never finalized from here.
  var liveCaptureId: UUID?
  private var working: Set<UUID> = []
  /// Failed remuxes, or failed transcriptions, before the walk moves on without that step.
  private static let maxStepAttempts = 3

  private init() {}

  /// At launch and on becoming active: finish anything left in progress.
  func resumeAll() {
    for capture in ScoutOutbox.shared.captures where capture.mode == .trackWalk
      && (capture.state == .recording || capture.state == .recorded) {
      Task { await advance(capture.id) }
    }
  }

  func advance(_ id: UUID) async {
    guard !working.contains(id), id != liveCaptureId else { return }
    working.insert(id)
    defer { working.remove(id) }

    if ScoutOutbox.shared.capture(id)?.state == .recording {
      await finalize(id)
    }
    if ScoutOutbox.shared.capture(id)?.state == .recorded {
      await transcribe(id)
    }
    ScoutOutbox.shared.resume()
  }

  /// .mov → .mp4 (a crash-recovered .mov is still readable up to its last fragment),
  /// then Photos. A missing recording still moves on, as a walk without video.
  /// After `maxStepAttempts` failed remuxes the walk moves on without video; the
  /// .mov is kept for inspection.
  private func finalize(_ id: UUID) async {
    let mov = TrackWalkMedia.url(for: id, ext: "mov")
    let mp4 = TrackWalkMedia.url(for: id, ext: "mp4")
    var videoName: String?
    if FileManager.default.fileExists(atPath: mov.path) {
      // Always from the .mov when it exists: an .mp4 beside it may be a half-written export.
      do {
        try await TrackWalkMedia.remux(mov, to: mp4)
        videoName = mp4.lastPathComponent
      } catch {
        NSLog("[TrackWalk] Remux failed for %@: %@", id.uuidString, error.localizedDescription)
        ScoutOutbox.shared.update(id) {
          $0.attempts += 1
          $0.lastError = "Video could not be finalized"
        }
        guard (ScoutOutbox.shared.capture(id)?.attempts ?? 0) >= Self.maxStepAttempts else {
          return  // Try again next launch; the .mov is kept.
        }
        NSLog("[TrackWalk] Giving up on the video for %@; keeping %@ for inspection", id.uuidString, mov.lastPathComponent)
        ScoutOutbox.shared.update(id) {
          OutboxRules.markRecorded(&$0, videoFileName: nil, savedToPhotos: false)
          $0.attempts = 0
        }
        return
      }
    } else if FileManager.default.fileExists(atPath: mp4.path) {
      videoName = mp4.lastPathComponent
    }
    if let videoName, ScoutOutbox.shared.capture(id)?.durationMin == 0 {
      // Crash-recovered: the controller never recorded the length, so read it from the file.
      let url = TrackWalkMedia.folder.appendingPathComponent(videoName)
      if let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric {
        let minutes = max(1, Int((duration.seconds / 60).rounded()))
        ScoutOutbox.shared.update(id) { $0.durationMin = minutes }
      }
    }
    var saved = ScoutOutbox.shared.capture(id)?.savedToPhotos ?? false
    if let videoName, !saved, SettingsManager.shared.trackWalkSaveToPhotos {
      saved = await TrackWalkMedia.saveToPhotos(TrackWalkMedia.folder.appendingPathComponent(videoName))
    }
    ScoutOutbox.shared.update(id) {
      OutboxRules.markRecorded(&$0, videoFileName: videoName, savedToPhotos: saved)
      $0.attempts = 0
    }
    if videoName != nil { try? FileManager.default.removeItem(at: mov) }
  }

  /// On-device transcription. A walk with no audio (or no video) becomes a silent
  /// walk, and so does one whose transcription failed `maxStepAttempts` times.
  private func transcribe(_ id: UUID) async {
    guard let capture = ScoutOutbox.shared.capture(id) else { return }
    var lines: [String] = []
    if let name = capture.videoFileName {
      let video = TrackWalkMedia.folder.appendingPathComponent(name)
      let m4a = TrackWalkMedia.url(for: id, ext: "m4a")
      do {
        if try await AVURLAsset(url: video).loadTracks(withMediaType: .audio).isEmpty {
          NSLog("[TrackWalk] %@ has no audio track; treating it as a silent walk", id.uuidString)
        } else {
          try await TrackWalkMedia.extractAudio(from: video, to: m4a)
          _ = await TrackWalkMedia.ensureSpeechModel()
          lines = try await TrackWalkMedia.transcribe(m4a)
        }
      } catch {
        NSLog("[TrackWalk] Transcription failed for %@: %@", id.uuidString, error.localizedDescription)
        try? FileManager.default.removeItem(at: m4a)
        ScoutOutbox.shared.update(id) {
          $0.attempts += 1
          $0.lastError = "Transcription failed; will retry"
        }
        guard (ScoutOutbox.shared.capture(id)?.attempts ?? 0) >= Self.maxStepAttempts else {
          return  // Stays .recorded; retried next launch or activation.
        }
        NSLog("[TrackWalk] Giving up on transcription for %@; sending it as a silent walk", id.uuidString)
        lines = []
      }
      try? FileManager.default.removeItem(at: m4a)
    }
    let testMode = capture.sessionId == "test-mode"
    ScoutOutbox.shared.update(id) {
      OutboxRules.markTranscribed(&$0, lines: lines)
      $0.attempts = 0
      $0.lastError = nil
      if testMode {
        // Like a Race in test mode, nothing is sent.
        $0.state = .done
        $0.lastError = "Test mode — not sent"
      }
    }
  }
}
