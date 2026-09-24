import Foundation

/// How a Track Walk's video may travel. Asked once per walk, only when on cellular.
public enum UploadNetwork: String, Codable, Sendable {
  case wifiOnly
  case cellularAllowed
}

/// Which background session carries an upload, or why none starts yet.
public enum UploadRoute: Equatable, Sendable {
  case wifiSession
  case cellularSession
  /// Ask "Upload now on cellular?", and meanwhile queue on the Wi-Fi session.
  case askUser
  /// No network at all: try again when the path changes.
  case wait
}

/// One step of a video's trip to SPECTRE, decided from a reply.
public enum UploadStep: Equatable, Sendable {
  /// PUT the file to this URL, then call complete for this item.
  case upload(mediaId: String, putURL: URL)
  /// The file is in storage: call complete.
  case complete(mediaId: String)
  /// SPECTRE has the video. Delete the local copy.
  case completed
  /// Storage refused the signature (probably expired): get a fresh token and upload again.
  case reupload
  /// Final: sending again unchanged would fail the same way.
  case rejected(String)
  /// Worth trying again later.
  case transient(String)
}

/// SPECTRE's Scout media contract (SPECTRE `docs/scout-media-contract.md`), as pure decisions.
public enum UploadRules {
  public static let maxReuploads = 3
  static let refusedOrExpired = "Upload refused or expired — upload the file again"
  static let unexpectedReply = "Unexpected reply from SPECTRE"

  public static func route(for capture: Capture, onWiFi: Bool, cellularAvailable: Bool) -> UploadRoute {
    if onWiFi { return .wifiSession }
    switch capture.uploadNetwork {
    case .wifiOnly: return .wifiSession
    case .cellularAllowed: return .cellularSession
    case nil: return cellularAvailable ? .askUser : .wait
    }
  }

  /// The reply to `POST /api/scout/media` or `POST /api/scout/media/<id>/token`.
  public static func classifyStart(status: Int, body: Data) -> UploadStep {
    switch status {
    case 200...299:
      guard let json = object(body), json["ok"] as? Bool == true,
            let mediaId = json["media_id"] as? String
      else { return .rejected(unexpectedReply) }
      if json["already_uploaded"] as? Bool == true { return .complete(mediaId: mediaId) }
      guard json["token"] is String,
            let put = json["put_url"] as? String, let putURL = URL(string: put)
      else { return .rejected(unexpectedReply) }
      return .upload(mediaId: mediaId, putURL: putURL)
    case 300...399:
      return .rejected("SPECTRE redirected the upload (HTTP \(status))")
    case 400, 401, 403, 404:
      return .rejected(errorText(body) ?? "HTTP \(status)")
    default:
      return .transient("SPECTRE error (HTTP \(status))")
    }
  }

  /// The reply to `POST /api/scout/media/<id>/complete`.
  public static func classifyComplete(status: Int, body: Data) -> UploadStep {
    switch status {
    case 200...299:
      guard let json = object(body), json["ok"] as? Bool == true else { return .rejected(unexpectedReply) }
      return .completed
    case 300...399:
      return .rejected("SPECTRE redirected the upload (HTTP \(status))")
    case 409:
      return .transient("Upload not found in storage yet")
    case 400:
      let text = errorText(body)
      return text == refusedOrExpired ? .reupload : .rejected(text ?? "HTTP 400")
    case 401, 403, 404:
      return .rejected(errorText(body) ?? "HTTP \(status)")
    default:
      return .transient("SPECTRE error (HTTP \(status))")
    }
  }

  /// The whole-file PUT to storage. `status` is nil when no reply arrived.
  /// Storage reports an expired signature as a 4xx; the exact code is unconfirmed,
  /// so 400, 401 and 403 all mean "get a fresh token and upload again".
  public static func classifyStorage(status: Int?, mediaId: String, networkError: String?) -> UploadStep {
    if let networkError { return .transient(networkError) }
    guard let status else { return .transient("No reply from storage") }
    switch status {
    case 200...299: return .complete(mediaId: mediaId)
    case 400, 401, 403: return .reupload
    case 413: return .rejected("Video too large for storage")
    case 408, 429, 500...599: return .transient("Storage error (HTTP \(status))")
    default: return .rejected("Storage refused the upload (HTTP \(status))")
    }
  }

  private static func object(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private static func errorText(_ data: Data) -> String? {
    object(data)?["error"] as? String
  }
}

/// The body of `POST /api/scout/media` for a Track Walk video.
public enum MediaRequest {
  public static let mimeType = "video/mp4"

  private struct CreateBody: Encodable {
    let sessionId: String
    let kind: String
    let mimeType: String
    let sizeBytes: Int64
    let durationSec: Double
    let capturedAt: String
    let capturedTz: String
    let scoutContext: String
    let captureId: String

    enum CodingKeys: String, CodingKey {
      case sessionId = "session_id"
      case kind
      case mimeType = "mime_type"
      case sizeBytes = "size_bytes"
      case durationSec = "duration_sec"
      case capturedAt = "captured_at"
      case capturedTz = "captured_tz"
      case scoutContext = "scout_context"
      case captureId = "capture_id"
    }
  }

  /// `captured_at` is the walk's start, written in the zone it was recorded in
  /// (or `fallbackZone` for a walk saved before zones were stored), with its offset.
  public static func createBody(
    for capture: Capture, sizeBytes: Int64, durationSec: Double, fallbackZone: TimeZone = .current
  ) throws -> Data {
    let zone = capture.timeZone.flatMap { TimeZone(identifier: $0) } ?? fallbackZone
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = zone
    let body = CreateBody(
      sessionId: capture.sessionId,
      kind: "video",
      mimeType: mimeType,
      sizeBytes: sizeBytes,
      durationSec: (durationSec * 10).rounded() / 10,
      capturedAt: formatter.string(from: capture.createdAt),
      capturedTz: zone.identifier,
      scoutContext: String(capture.scoutContext.prefix(100)),
      captureId: capture.id.uuidString.lowercased())
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(body)
  }
}
