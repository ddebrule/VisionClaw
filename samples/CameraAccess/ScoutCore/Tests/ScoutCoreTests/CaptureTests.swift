import XCTest
@testable import ScoutCore

final class CaptureTests: XCTestCase {
  private func race(createdAt: TimeInterval = 0) -> Capture {
    Capture(
      id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
      mode: .race,
      sessionId: "c0ffee00-0000-4000-8000-000000000001",
      trackName: "Mile High",
      transcript: [TranscriptLine(role: "user", text: "pushing in the sweeper")],
      scoutContext: "Driver Stand",
      vehicleModel: "Nitro Buggy",
      durationMin: 12,
      createdAt: Date(timeIntervalSince1970: createdAt))
  }

  func testNewCaptureIsPending() {
    let capture = race()
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.attempts, 0)
    XCTAssertNil(capture.lastError)
    XCTAssertTrue(capture.retryable)
  }

  func testPendingNeedsSend() {
    XCTAssertTrue(OutboxRules.needsSend(race()))
  }

  func testBeginSendCountsAttempt() {
    var capture = race()
    OutboxRules.beginSend(&capture)
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.attempts, 1)
  }

  func testAcceptedRaceIsDone() {
    var capture = race()
    OutboxRules.beginSend(&capture)
    OutboxRules.apply(.accepted, to: &capture)
    XCTAssertEqual(capture.state, .done)
    XCTAssertNil(capture.lastError)
    XCTAssertFalse(OutboxRules.needsSend(capture))
  }

  func testAcceptedTrackWalkIsReported() {
    var capture = Capture(
      mode: .trackWalk, sessionId: "s", trackName: "t", transcript: [],
      scoutContext: "Track Walk", vehicleModel: "", durationMin: 7)
    OutboxRules.apply(.accepted, to: &capture)
    XCTAssertEqual(capture.state, .reported)
  }

  func testTransientFailureIsRetryable() {
    var capture = race()
    OutboxRules.beginSend(&capture)
    OutboxRules.apply(.transientFailure("offline"), to: &capture)
    XCTAssertEqual(capture.state, .failed)
    XCTAssertTrue(capture.retryable)
    XCTAssertEqual(capture.lastError, "offline")
  }

  func testNeedsSendAfterTransientFailure() {
    var capture = race()
    OutboxRules.apply(.transientFailure("offline"), to: &capture)
    XCTAssertTrue(OutboxRules.needsSend(capture))
    OutboxRules.beginSend(&capture)
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.attempts, 1)
  }

  func testRejectedIsNotAutoRetried() {
    var capture = race()
    OutboxRules.apply(.rejected("HTTP 404"), to: &capture)
    XCTAssertEqual(capture.state, .failed)
    XCTAssertFalse(capture.retryable)
    XCTAssertFalse(OutboxRules.needsSend(capture))
  }

  func testManualRetryRevivesRejected() {
    var capture = race()
    OutboxRules.apply(.rejected("HTTP 404"), to: &capture)
    OutboxRules.retry(&capture)
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertTrue(capture.retryable)
    XCTAssertNil(capture.lastError)
    XCTAssertTrue(OutboxRules.needsSend(capture))
  }

  func testRetryLeavesDoneAlone() {
    var capture = race()
    OutboxRules.apply(.accepted, to: &capture)
    OutboxRules.retry(&capture)
    XCTAssertEqual(capture.state, .done)
  }

  func testPruneKeepsNewestDoneAndAllOthers() {
    var captures: [Capture] = []
    for index in 0..<5 {
      var done = Capture(
        mode: .race, sessionId: "s", trackName: "t", transcript: [],
        scoutContext: "Driver Stand", vehicleModel: "", durationMin: 1,
        createdAt: Date(timeIntervalSince1970: Double(index)))
      OutboxRules.apply(.accepted, to: &done)
      captures.append(done)
    }
    captures.append(race(createdAt: -100))  // old but still pending
    let kept = OutboxRules.pruned(captures, keepingDone: 2)
    XCTAssertEqual(kept.count, 3)
    XCTAssertEqual(kept.filter { $0.state == .done }.map(\.createdAt.timeIntervalSince1970), [3, 4])
    XCTAssertTrue(kept.contains { $0.state == .reportPending })
  }

  func testManifestRoundTrip() throws {
    var failed = race(createdAt: 1_700_000_000)
    OutboxRules.apply(.transientFailure("offline"), to: &failed)
    let data = try OutboxCoding.encode([failed, race(createdAt: 1_700_000_100)])
    XCTAssertEqual(try OutboxCoding.decode(data), [failed, race(createdAt: 1_700_000_100)])
  }

  func testDecodeRejectsUnknownVersion() {
    let data = Data(#"{"version":99,"captures":[]}"#.utf8)
    XCTAssertThrowsError(try OutboxCoding.decode(data))
  }
}
