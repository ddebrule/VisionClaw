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
  private func finalize(_ id: UUID) async {
    let mov = TrackWalkMedia.url(for: id, ext: "mov")
    let mp4 = TrackWalkMedia.url(for: id, ext: "mp4")
    var videoName: String?
    if FileManager.default.fileExists(atPath: mp4.path) {
      videoName = mp4.lastPathComponent
    } else if FileManager.default.fileExists(atPath: mov.path) {
      do {
        try await TrackWalkMedia.remux(mov, to: mp4)
        videoName = mp4.lastPathComponent
      } catch {
        NSLog("[TrackWalk] Remux failed for %@: %@", id.uuidString, error.localizedDescription)
        ScoutOutbox.shared.update(id) { $0.lastError = "Video could not be finalized" }
        return  // Try again next launch; the .mov is kept.
      }
    }
    var saved = ScoutOutbox.shared.capture(id)?.savedToPhotos ?? false
    if let videoName, !saved, SettingsManager.shared.trackWalkSaveToPhotos {
      saved = await TrackWalkMedia.saveToPhotos(TrackWalkMedia.folder.appendingPathComponent(videoName))
    }
    ScoutOutbox.shared.update(id) { OutboxRules.markRecorded(&$0, videoFileName: videoName, savedToPhotos: saved) }
    if videoName != nil { try? FileManager.default.removeItem(at: mov) }
  }

  /// On-device transcription. A walk with no audio (or no video) becomes a silent walk.
  private func transcribe(_ id: UUID) async {
    guard let capture = ScoutOutbox.shared.capture(id) else { return }
    var lines: [String] = []
    if let name = capture.videoFileName {
      let video = TrackWalkMedia.folder.appendingPathComponent(name)
      let m4a = TrackWalkMedia.url(for: id, ext: "m4a")
      do {
        try await TrackWalkMedia.extractAudio(from: video, to: m4a)
        _ = await TrackWalkMedia.ensureSpeechModel()
        lines = try await TrackWalkMedia.transcribe(m4a)
      } catch {
        NSLog("[TrackWalk] Transcription failed for %@: %@", id.uuidString, error.localizedDescription)
        ScoutOutbox.shared.update(id) { $0.lastError = "Transcription failed; will retry" }
        try? FileManager.default.removeItem(at: m4a)
        return  // Stays .recorded; retried next launch or activation.
      }
      try? FileManager.default.removeItem(at: m4a)
    }
    ScoutOutbox.shared.update(id) {
      OutboxRules.markTranscribed(&$0, lines: lines)
      $0.lastError = nil
    }
  }
}
