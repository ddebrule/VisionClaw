import AVFoundation
import Foundation
import Photos
import Speech

/// Files, storage, Photos and on-device transcription for Track Walk.
enum TrackWalkMedia {
  /// Application Support/TrackWalks — recordings live here until uploaded (Plan 7).
  static let folder: URL = {
    let folder = URL.applicationSupportDirectory.appending(path: "TrackWalks", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
  }()

  static func url(for id: UUID, ext: String) -> URL {
    folder.appending(path: "\(id.uuidString).\(ext)", directoryHint: .notDirectory)
  }

  /// Space available for a user-requested save, in bytes.
  static func freeBytes() -> Int64? {
    let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  /// Fragmented .mov → .mp4, no re-encode.
  static func remux(_ mov: URL, to mp4: URL) async throws {
    try? FileManager.default.removeItem(at: mp4)
    let asset = AVURLAsset(url: mov)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      throw CocoaError(.fileWriteUnknown)
    }
    export.shouldOptimizeForNetworkUse = true
    try await export.export(to: mp4, as: .mp4)
  }

  /// Adds the video to Photos with add-only permission. False on any failure.
  static func saveToPhotos(_ url: URL) async -> Bool {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else { return false }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil)
      }
      return true
    } catch {
      NSLog("[TrackWalk] Photos save failed: %@", error.localizedDescription)
      return false
    }
  }

  /// The narration track as .m4a, for the speech analyzer.
  static func extractAudio(from video: URL, to m4a: URL) async throws {
    try? FileManager.default.removeItem(at: m4a)
    let asset = AVURLAsset(url: video)
    guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try await export.export(to: m4a, as: .m4a)
  }

  private static func transcriber() async -> SpeechTranscriber {
    let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
      ?? Locale(identifier: "en-US")
    return SpeechTranscriber(locale: locale, preset: .transcription)
  }

  /// Downloads the speech model now if it is missing (preflight, while online).
  static func ensureSpeechModel() async -> Bool {
    let module = await transcriber()
    do {
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
        try await request.downloadAndInstall()
      }
      return true
    } catch {
      NSLog("[TrackWalk] Speech model unavailable: %@", error.localizedDescription)
      return false
    }
  }

  /// On-device transcription of a recorded file; one string per finalized phrase.
  static func transcribe(_ audio: URL) async throws -> [String] {
    let module = await transcriber()
    let analyzer = SpeechAnalyzer(modules: [module])
    let collector = Task { () -> [String] in
      var lines: [String] = []
      for try await result in module.results where result.isFinal {
        lines.append(String(result.text.characters))
      }
      return lines
    }
    do {
      let file = try AVAudioFile(forReading: audio)
      if let last = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: last)
      } else {
        await analyzer.cancelAndFinishNow()
      }
    } catch {
      // Close the results sequence so the collector does not wait forever.
      await analyzer.cancelAndFinishNow()
      collector.cancel()
      throw error
    }
    return try await collector.value
  }
}
