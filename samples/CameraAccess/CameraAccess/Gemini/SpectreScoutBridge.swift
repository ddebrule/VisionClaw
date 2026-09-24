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
      throw NSError(domain: "SpectreScout", code: 404, userInfo: [NSLocalizedDescriptionKey: "No active Spectre session. Start a session on your iPad first."])
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

  /// Send the accumulated field report to Spectre Setup_IQ.
  func sendReport(
    sessionId: String,
    transcript: [ScoutTranscriptEntry],
    durationMin: Int,
    scoutContext: String,
    vehicleModel: String
  ) async throws {
    guard let url = URL(string: GeminiConfig.spectreScoutURL) else { throw URLError(.badURL) }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")

    let transcriptArray = transcript.map { ["role": $0.role, "text": $0.text] }
    let body: [String: Any] = [
      "session_id": sessionId,
      "transcript": transcriptArray,
      "duration_min": durationMin,
      "scout_context": scoutContext,
      "vehicle_model": vehicleModel,
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    NSLog("[SpectreScout] Report sent. Context: %@, Vehicle: %@, Turns: %d, Duration: %d min",
          scoutContext, vehicleModel, transcript.count, durationMin)
  }
}
