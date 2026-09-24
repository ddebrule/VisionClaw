import Foundation

/// Which Scout mode produced a capture.
public enum CaptureMode: String, Codable, Sendable {
  case race
  case trackWalk
}

/// Where a capture is in its trip to SPECTRE. Race: reportPending → done.
/// Track Walk (Plan 6/7) continues from reported to its video upload.
public enum CaptureState: String, Codable, Sendable {
  case reportPending
  case reported
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
  public let transcript: [TranscriptLine]
  public let scoutContext: String
  public let vehicleModel: String
  public let durationMin: Int
  public let createdAt: Date
  public var state: CaptureState
  public var attempts: Int
  public var lastError: String?
  /// False after SPECTRE refused the report outright; only a manual Retry sends it again.
  public var retryable: Bool

  public init(
    id: UUID = UUID(),
    mode: CaptureMode,
    sessionId: String,
    trackName: String,
    transcript: [TranscriptLine],
    scoutContext: String,
    vehicleModel: String,
    durationMin: Int,
    createdAt: Date = Date()
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
    self.state = .reportPending
    self.attempts = 0
    self.lastError = nil
    self.retryable = true
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
  public static func needsSend(_ capture: Capture) -> Bool {
    switch capture.state {
    case .reportPending: return true
    case .failed: return capture.retryable
    case .reported, .done: return false
    }
  }

  public static func beginSend(_ capture: inout Capture) {
    capture.state = .reportPending
    capture.attempts += 1
  }

  public static func apply(_ outcome: ReportOutcome, to capture: inout Capture) {
    switch outcome {
    case .accepted:
      capture.state = capture.mode == .race ? .done : .reported
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
  public static func retry(_ capture: inout Capture) {
    guard capture.state == .failed else { return }
    capture.state = .reportPending
    capture.lastError = nil
    capture.retryable = true
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
