import XCTest
@testable import ScoutCore

final class UploadTests: XCTestCase {
  private func walk(network: UploadNetwork? = nil) -> Capture {
    var capture = Capture(
      id: UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")!,
      mode: .trackWalk, sessionId: "c0ffee00-0000-4000-8000-000000000002",
      trackName: "Mile High", transcript: [], scoutContext: "Track Walk",
      vehicleModel: "", durationMin: 7,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      state: .reported, videoFileName: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE.mp4")
    capture.uploadNetwork = network
    return capture
  }

  private func json(_ text: String) -> Data { Data(text.utf8) }

  // MARK: route

  func testWiFiAlwaysUsesWiFiSession() {
    XCTAssertEqual(UploadRules.route(for: walk(), onWiFi: true, cellularAvailable: false), .wifiSession)
    XCTAssertEqual(UploadRules.route(for: walk(network: .cellularAllowed), onWiFi: true, cellularAvailable: true), .wifiSession)
  }

  func testCellularWithoutChoiceAsks() {
    XCTAssertEqual(UploadRules.route(for: walk(), onWiFi: false, cellularAvailable: true), .askUser)
  }

  func testNoNetworkWithoutChoiceWaits() {
    XCTAssertEqual(UploadRules.route(for: walk(), onWiFi: false, cellularAvailable: false), .wait)
  }

  func testChosenNetworkIsUsedOffWiFi() {
    XCTAssertEqual(UploadRules.route(for: walk(network: .wifiOnly), onWiFi: false, cellularAvailable: true), .wifiSession)
    XCTAssertEqual(UploadRules.route(for: walk(network: .cellularAllowed), onWiFi: false, cellularAvailable: true), .cellularSession)
  }

  // MARK: create / token replies

  func testStartNewItemUploads() {
    let body = json(#"{"ok":true,"media_id":"m-1","path":"u/s/m-1.mp4","token":"t","upload_url":"https://s.test/tus","put_url":"https://s.test/put?token=t"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body),
                   .upload(mediaId: "m-1", putURL: URL(string: "https://s.test/put?token=t")!))
  }

  func testStartDuplicateWithTokenUploads() {
    let body = json(#"{"ok":true,"duplicate":true,"media_id":"m-1","path":"p","token":"t2","upload_url":"https://s.test/tus","put_url":"https://s.test/put2"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body),
                   .upload(mediaId: "m-1", putURL: URL(string: "https://s.test/put2")!))
  }

  func testStartAlreadyUploadedSkipsToComplete() {
    let body = json(#"{"ok":true,"duplicate":true,"already_uploaded":true,"media_id":"m-1","path":"p"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body), .complete(mediaId: "m-1"))
  }

  func testStartMissingPutURLIsRejected() {
    let body = json(#"{"ok":true,"media_id":"m-1","token":"t"}"#)
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: body), .rejected("Unexpected reply from SPECTRE"))
  }

  func testStartHTML200IsRejected() {
    XCTAssertEqual(UploadRules.classifyStart(status: 200, body: json("<html>login</html>")),
                   .rejected("Unexpected reply from SPECTRE"))
  }

  func testStartRedirectIsRejected() {
    XCTAssertEqual(UploadRules.classifyStart(status: 307, body: Data()),
                   .rejected("SPECTRE redirected the upload (HTTP 307)"))
  }

  func testStart400UsesSpectreMessage() {
    XCTAssertEqual(UploadRules.classifyStart(status: 400, body: json(#"{"error":"Over 15 min — trim it"}"#)),
                   .rejected("Over 15 min — trim it"))
  }

  func testStart404WithoutBody() {
    XCTAssertEqual(UploadRules.classifyStart(status: 404, body: Data()), .rejected("HTTP 404"))
  }

  func testStart500IsTransient() {
    XCTAssertEqual(UploadRules.classifyStart(status: 500, body: json(#"{"error":"Try again"}"#)),
                   .transient("SPECTRE error (HTTP 500)"))
  }

  func testStart429IsTransient() {
    XCTAssertEqual(UploadRules.classifyStart(status: 429, body: Data()), .transient("SPECTRE error (HTTP 429)"))
  }

  // MARK: complete replies

  func testCompleteOk() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 200, body: json(#"{"ok":true}"#)), .completed)
  }

  func testCompleteNeedsOk() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 200, body: json("<html></html>")),
                   .rejected("Unexpected reply from SPECTRE"))
  }

  func testComplete409IsTransient() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 409, body: json(#"{"error":"Upload not found in storage yet"}"#)),
                   .transient("Upload not found in storage yet"))
  }

  func testCompleteRefusedOrExpiredIsReupload() {
    let body = json(#"{"error":"Upload refused or expired — upload the file again"}"#)
    XCTAssertEqual(UploadRules.classifyComplete(status: 400, body: body), .reupload)
  }

  func testCompleteLimitIsRejected() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 400, body: json(#"{"error":"File type does not match"}"#)),
                   .rejected("File type does not match"))
  }

  func testCompleteRedirectIsRejected() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 302, body: Data()),
                   .rejected("SPECTRE redirected the upload (HTTP 302)"))
  }

  func testComplete500IsTransient() {
    XCTAssertEqual(UploadRules.classifyComplete(status: 503, body: Data()), .transient("SPECTRE error (HTTP 503)"))
  }

  // MARK: storage PUT

  func testStorage200GoesToComplete() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 200, mediaId: "m-1", networkError: nil), .complete(mediaId: "m-1"))
  }

  func testStorage403IsReupload() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 403, mediaId: "m-1", networkError: nil), .reupload)
    XCTAssertEqual(UploadRules.classifyStorage(status: 400, mediaId: "m-1", networkError: nil), .reupload)
    XCTAssertEqual(UploadRules.classifyStorage(status: 401, mediaId: "m-1", networkError: nil), .reupload)
  }

  func testStorage413IsRejected() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 413, mediaId: "m-1", networkError: nil),
                   .rejected("Video too large for storage"))
  }

  func testStorageNetworkErrorIsTransient() {
    XCTAssertEqual(UploadRules.classifyStorage(status: nil, mediaId: "m-1", networkError: "The network connection was lost."),
                   .transient("The network connection was lost."))
  }

  func testStorageNoReplyIsTransient() {
    XCTAssertEqual(UploadRules.classifyStorage(status: nil, mediaId: "m-1", networkError: nil), .transient("No reply from storage"))
  }

  func testStorage500IsTransient() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 502, mediaId: "m-1", networkError: nil), .transient("Storage error (HTTP 502)"))
  }

  func testStorageRedirectIsRejected() {
    XCTAssertEqual(UploadRules.classifyStorage(status: 307, mediaId: "m-1", networkError: nil),
                   .rejected("Storage refused the upload (HTTP 307)"))
  }

  // MARK: create body

  func testCreateBody() throws {
    var capture = walk()
    capture.timeZone = "America/Denver"
    let data = try MediaRequest.createBody(for: capture, sizeBytes: 734_003_200, durationSec: 421.37)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(body["session_id"] as? String, "c0ffee00-0000-4000-8000-000000000002")
    XCTAssertEqual(body["kind"] as? String, "video")
    XCTAssertEqual(body["mime_type"] as? String, "video/mp4")
    XCTAssertEqual(body["size_bytes"] as? Int, 734_003_200)
    XCTAssertEqual(body["duration_sec"] as? Double, 421.4)
    XCTAssertEqual(body["captured_at"] as? String, "2023-11-14T15:13:20-07:00")
    XCTAssertEqual(body["captured_tz"] as? String, "America/Denver")
    XCTAssertEqual(body["scout_context"] as? String, "Track Walk")
    XCTAssertEqual(body["capture_id"] as? String, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
    XCTAssertNil(body["vehicle_id"])
    XCTAssertEqual(body.count, 9)
  }

  func testCreateBodyFallsBackToGivenZone() throws {
    let data = try MediaRequest.createBody(
      for: walk(), sizeBytes: 1, durationSec: 1, fallbackZone: TimeZone(identifier: "Asia/Tokyo")!)
    let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(body["captured_at"] as? String, "2023-11-15T07:13:20+09:00")
    XCTAssertEqual(body["captured_tz"] as? String, "Asia/Tokyo")
  }
}
