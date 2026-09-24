import Foundation

/// Which Scout mode produced a capture.
public enum CaptureMode: String, Codable, Sendable {
  case race
  case trackWalk
}

/// Where a capture is in its trip to SPECTRE. Race: reportPending → done.
/// Track Walk: recording → recorded → reportPending → reported → uploading → done.
/// `failed` can follow any network step; `reportAccepted` says which side of the report it is on.
public enum CaptureState: String, Codable, Sendable {
  case recording
  case recorded
  case reportPending
  case reported
  case uploading
  case done
  case failed
}

public struct TranscriptLine: Codable, Equatable, Sendable {
  public let role: String
  public let text: String

  public init(role: String, text: String) {
    self.role = role
    self.text = text
  }
}

/// One report on its way to SPECTRE. `id` is sent as `capture_id`, so a
/// retried send can never create a second report once SPECTRE dedupes on it.
public struct Capture: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public let mode: CaptureMode
  public let sessionId: String
  public let trackName: String
  public var transcript: [TranscriptLine]
  public let scoutContext: String
  public let vehicleModel: String
  public var durationMin: Int
  public let createdAt: Date
  public var state: CaptureState
  public var attempts: Int
  public var lastError: String?
  /// False after SPECTRE refused the report outright; only a manual Retry sends it again.
  public var retryable: Bool
  /// Track Walk: the recording's file name inside Application Support/TrackWalks.
  public var videoFileName: String?
  /// Track Walk: true when no speech was recognised (SPECTRE then skips layout extraction).
  public var noNarration: Bool?
  /// Track Walk: already saved to the Photos library.
  public var savedToPhotos: Bool?
  /// Track Walk: SPECTRE accepted the text report, so a failure after this is the video's.
  public var reportAccepted: Bool?
  /// Track Walk: SPECTRE's media item for the video, once created.
  public var mediaId: String?
  /// Track Walk: the owner's answer to "Upload now on cellular?"; nil until asked.
  public var uploadNetwork: UploadNetwork?
  /// Track Walk: uploads storage refused (expired signature) since the last success or Retry.
  public var uploadAttempts: Int?
  /// Track Walk: the IANA time zone the walk was recorded in.
  public var timeZone: String?

  public init(
    id: UUID = UUID(),
    mode: CaptureMode,
    sessionId: String,
    trackName: String,
    transcript: [TranscriptLine],
    scoutContext: String,
    vehicleModel: String,
    durationMin: Int,
    createdAt: Date = Date(),
    state: CaptureState = .reportPending,
    videoFileName: String? = nil
  ) {
    self.id = id
    self.mode = mode
    self.sessionId = sessionId
    self.trackName = trackName
    self.transcript = transcript
    self.scoutContext = scoutContext
    self.vehicleModel = vehicleModel
    self.durationMin = durationMin
    self.createdAt = createdAt
    self.state = state
    self.attempts = 0
    self.lastError = nil
    self.retryable = true
    self.videoFileName = videoFileName
    self.noNarration = nil
    self.savedToPhotos = nil
    self.reportAccepted = nil
    self.mediaId = nil
    self.uploadNetwork = nil
    self.uploadAttempts = nil
    self.timeZone = nil
  }
}

/// The result of one attempt to post a capture's report.
public enum ReportOutcome: Equatable, Sendable {
  case accepted
  /// SPECTRE refused it (4xx); sending again unchanged would fail the same way.
  case rejected(String)
  /// Network error or server trouble; worth sending again later.
  case transientFailure(String)
}

/// Pure state rules for the Outbox. Every step is safe to repeat.
public enum OutboxRules {
  public static let silentWalkLine = "(Silent walk — no narration recorded.)"

  /// The app's own spoken Track Walk cues (lower case). The mic hears them, but
  /// they are not narration, so they are dropped from a walk's transcript.
  public static let cuePhrases: Set<String> = [
    "recording started", "recording", "paused", "two minutes left",
    "stopped", "storage full, saved", "recording failed",
  ]

  public static func needsSend(_ capture: Capture, trackWalkReportsEnabled: Bool = true) -> Bool {
    if capture.mode == .trackWalk && !trackWalkReportsEnabled { return false }
    switch capture.state {
    case .reportPending: return true
    case .failed: return capture.retryable && capture.reportAccepted != true
    case .recording, .recorded, .reported, .uploading, .done: return false
    }
  }

  /// A Track Walk's recording is finalized (the file exists as .mp4, or was lost).
  public static func markRecorded(_ capture: inout Capture, videoFileName: String?, savedToPhotos: Bool) {
    capture.videoFileName = videoFileName
    capture.savedToPhotos = savedToPhotos
    capture.state = .recorded
  }

  /// Transcription done: the report is ready. Blank lines and the app's own cues
  /// are dropped; no speech at all becomes a single placeholder line with noNarration set.
  public static func markTranscribed(_ capture: inout Capture, lines: [String]) {
    let spoken = lines
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !isCue($0) }
      .filter { !$0.isEmpty }
    capture.noNarration = spoken.isEmpty
    capture.transcript = spoken.isEmpty
      ? [TranscriptLine(role: "user", text: silentWalkLine)]
      : spoken.map { TranscriptLine(role: "user", text: $0) }
    capture.state = .reportPending
  }

  private static func isCue(_ line: String) -> Bool {
    let bare = line
      .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
      .lowercased()
    return cuePhrases.contains(bare)
  }

  public static func beginSend(_ capture: inout Capture) {
    capture.state = .reportPending
    capture.attempts += 1
  }

  public static func apply(_ outcome: ReportOutcome, to capture: inout Capture) {
    switch outcome {
    case .accepted:
      if capture.mode == .race {
        capture.state = .done
      } else {
        capture.reportAccepted = true
        capture.state = capture.videoFileName == nil ? .done : .reported
      }
      capture.lastError = nil
      capture.retryable = true
    case .rejected(let reason):
      capture.state = .failed
      capture.lastError = reason
      capture.retryable = false
    case .transientFailure(let reason):
      capture.state = .failed
      capture.lastError = reason
      capture.retryable = true
    }
  }

  /// The user's Retry: revives any failed capture, including a rejected one.
  /// A walk whose report SPECTRE already has goes back to its upload, never re-sending the report.
  public static func retry(_ capture: inout Capture) {
    guard capture.state == .failed else { return }
    if capture.reportAccepted == true {
      capture.state = .reported
      capture.uploadAttempts = 0
    } else {
      capture.state = .reportPending
    }
    capture.lastError = nil
    capture.retryable = true
  }

  /// A Track Walk whose video still has to reach SPECTRE. `.uploading` is included:
  /// the app checks separately whether a background task is already carrying it.
  public static func needsUpload(_ capture: Capture, trackWalkReportsEnabled: Bool = true) -> Bool {
    guard capture.mode == .trackWalk, trackWalkReportsEnabled, capture.videoFileName != nil else { return false }
    switch capture.state {
    case .reported, .uploading: return true
    case .failed: return capture.retryable && capture.reportAccepted == true
    case .recording, .recorded, .reportPending, .done: return false
    }
  }

  /// SPECTRE created (or re-issued) the media item; bytes are about to move.
  public static func beginUpload(_ capture: inout Capture, mediaId: String) {
    capture.mediaId = mediaId
    capture.state = .uploading
    capture.lastError = nil
  }

  /// Records a finished upload step. `.upload` and `.complete` are steps still
  /// in progress and change nothing.
  public static func applyUpload(_ step: UploadStep, to capture: inout Capture) {
    switch step {
    case .upload, .complete:
      return
    case .completed:
      capture.state = .done
      capture.lastError = nil
      capture.retryable = true
      capture.uploadAttempts = 0
    case .reupload:
      let attempts = (capture.uploadAttempts ?? 0) + 1
      capture.uploadAttempts = attempts
      if attempts >= UploadRules.maxReuploads {
        capture.state = .failed
        capture.lastError = "Upload refused: storage kept refusing the video"
        capture.retryable = false
      } else {
        capture.state = .reported
      }
    case .rejected(let reason):
      capture.state = .failed
      capture.lastError = "Upload refused: \(reason)"
      capture.retryable = false
    case .transient(let reason):
      capture.state = .failed
      capture.lastError = reason
      capture.retryable = true
    }
  }

  /// Keeps every capture that is not done, plus the newest `keepingDone` done ones.
  public static func pruned(_ captures: [Capture], keepingDone: Int) -> [Capture] {
    let done = captures.filter { $0.state == .done }.sorted { $0.createdAt < $1.createdAt }
    let keptDone = Set(done.suffix(keepingDone).map(\.id))
    return captures.filter { $0.state != .done || keptDone.contains($0.id) }
  }
}

/// The Outbox manifest on disk: `{"version":1,"captures":[…]}`, dates in ISO 8601.
public enum OutboxCoding {
  public static let version = 1

  private struct Manifest: Codable {
    let version: Int
    let captures: [Capture]
  }

  public struct UnsupportedVersion: Error, Equatable {
    public let version: Int
  }

  public static func encode(_ captures: [Capture]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(Manifest(version: version, captures: captures))
  }

  public static func decode(_ data: Data) throws -> [Capture] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(Manifest.self, from: data)
    guard manifest.version == version else { throw UnsupportedVersion(version: manifest.version) }
    return manifest.captures
  }
}
