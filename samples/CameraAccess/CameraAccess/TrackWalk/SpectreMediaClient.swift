import Foundation

/// SPECTRE's Scout media routes: create, token and complete. Never throws;
/// every reply becomes an `UploadStep` (see `UploadRules`).
@MainActor
final class SpectreMediaClient {
  private let session: URLSession

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    session = URLSession(configuration: config)
  }

  /// `POST /api/scout/media`. Safe to repeat: the capture_id makes SPECTRE return the same item.
  func create(_ capture: Capture, sizeBytes: Int64, durationSec: Double) async -> UploadStep {
    guard let body = try? MediaRequest.createBody(for: capture, sizeBytes: sizeBytes, durationSec: durationSec) else {
      return .rejected("Could not build the upload request")
    }
    return await post(GeminiConfig.spectreMediaURL, body: body, classify: UploadRules.classifyStart)
  }

  /// A fresh upload token for an item that already exists, fetched just before uploading.
  func token(mediaId: String) async -> UploadStep {
    await post(GeminiConfig.spectreMediaURL + "/\(mediaId)/token", body: nil, classify: UploadRules.classifyStart)
  }

  func complete(mediaId: String) async -> UploadStep {
    await post(GeminiConfig.spectreMediaURL + "/\(mediaId)/complete", body: nil, classify: UploadRules.classifyComplete)
  }

  private func post(_ address: String, body: Data?, classify: (Int, Data) -> UploadStep) async -> UploadStep {
    guard let url = URL(string: address) else { return .rejected("SPECTRE URL not configured") }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")
    if let body {
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = body
    }
    do {
      let (data, response) = try await session.data(for: request, delegate: RedirectRefuser())
      guard let http = response as? HTTPURLResponse else { return .transient("No HTTP response") }
      return classify(http.statusCode, data)
    } catch {
      return .transient(error.localizedDescription)
    }
  }
}
