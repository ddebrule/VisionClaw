import Foundation

// MARK: - Scout data types

struct ScoutTranscriptEntry {
  let role: String  // "user" or "assistant"
  let text: String
}

struct ActiveSessionInfo {
  let sessionId: String
  let track: String
  let vehicles: [String]  // vehicle model names
}

// MARK: - SpectreScoutBridge

@MainActor
class SpectreScoutBridge {
  private let session: URLSession

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    self.session = URLSession(configuration: config)
  }

  /// Fetch the racer's current active Spectre session and vehicle list.
  func fetchActiveSession() async throws -> ActiveSessionInfo {
    guard let url = URL(string: GeminiConfig.spectreActiveSessionURL) else { throw URLError(.badURL) }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")

    let (data, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

    if http.statusCode == 404 {
      throw NSError(domain: "SpectreScout", code: 404, userInfo: [NSLocalizedDescriptionKey: "No live session — activate one in SPECTRE first."])
    }
    guard (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }

    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sessionId = json["session_id"] as? String,
          let track = json["track"] as? String,
          let vehiclesRaw = json["vehicles"] as? [[String: Any]]
    else { throw URLError(.cannotParseResponse) }

    let vehicleModels = vehiclesRaw.compactMap { $0["model"] as? String }
    NSLog("[SpectreScout] Active session: %@ (%@). Vehicles: %@", track, sessionId, vehicleModels.joined(separator: ", "))
    return ActiveSessionInfo(sessionId: sessionId, track: track, vehicles: vehicleModels)
  }

  /// Posts one capture's report. Never throws: the Outbox needs to know whether
  /// to retry, not why a Swift error surfaced.
  func deliver(_ capture: Capture) async -> ReportOutcome {
    guard let url = URL(string: GeminiConfig.spectreScoutURL) else {
      return .rejected("SPECTRE URL not configured")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")

    let body: [String: Any] = [
      "capture_id": capture.id.uuidString.lowercased(),
      "session_id": capture.sessionId,
      "transcript": capture.transcript.map { ["role": $0.role, "text": $0.text] },
      "duration_min": capture.durationMin,
      "scout_context": capture.scoutContext,
      "vehicle_model": capture.vehicleModel,
    ]
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (_, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse else {
        return .transientFailure("No HTTP response")
      }
      switch http.statusCode {
      case 200...299:
        NSLog("[SpectreScout] Report %@ accepted (%d turns, %d min)",
              capture.id.uuidString, capture.transcript.count, capture.durationMin)
        return .accepted
      case 400, 401, 403, 404:
        return .rejected("SPECTRE refused the report (HTTP \(http.statusCode))")
      default:
        return .transientFailure("SPECTRE error (HTTP \(http.statusCode))")
      }
    } catch {
      return .transientFailure(error.localizedDescription)
    }
  }
}
