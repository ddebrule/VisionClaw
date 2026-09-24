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

  private func walk(state: CaptureState = .recording) -> Capture {
    Capture(
      id: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
      mode: .trackWalk, sessionId: "c0ffee00-0000-4000-8000-000000000002",
      trackName: "Mile High", transcript: [], scoutContext: "Track Walk",
      vehicleModel: "", durationMin: 0,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000),
      state: state, videoFileName: "22222222-3333-4444-5555-666666666666.mov")
  }

  func testRecordingCaptureIsNotSendable() {
    XCTAssertFalse(OutboxRules.needsSend(walk()))
    XCTAssertFalse(OutboxRules.needsSend(walk(state: .recorded)))
  }

  func testMarkRecordedMovesToRecorded() {
    var capture = walk()
    OutboxRules.markRecorded(&capture, videoFileName: "x.mp4", savedToPhotos: true)
    XCTAssertEqual(capture.state, .recorded)
    XCTAssertEqual(capture.videoFileName, "x.mp4")
    XCTAssertEqual(capture.savedToPhotos, true)
  }

  func testMarkTranscribedWithSpeech() {
    var capture = walk(state: .recorded)
    OutboxRules.markTranscribed(&capture, lines: ["double into the triple", "  ", "sweeper is blown out"])
    XCTAssertEqual(capture.state, .reportPending)
    XCTAssertEqual(capture.noNarration, false)
    XCTAssertEqual(capture.transcript, [
      TranscriptLine(role: "user", text: "double into the triple"),
      TranscriptLine(role: "user", text: "sweeper is blown out"),
    ])
  }

  func testSilentWalkGetsPlaceholder() {
    var capture = walk(state: .recorded)
    OutboxRules.markTranscribed(&capture, lines: ["", "   "])
    XCTAssertEqual(capture.noNarration, true)
    XCTAssertEqual(capture.transcript, [TranscriptLine(role: "user", text: "(Silent walk — no narration recorded.)")])
    XCTAssertEqual(OutboxRules.silentWalkLine, "(Silent walk — no narration recorded.)")
  }

  func testHeldTrackWalkIsNotSent() {
    var capture = walk(state: .recorded)
    OutboxRules.markTranscribed(&capture, lines: ["line"])
    XCTAssertFalse(OutboxRules.needsSend(capture, trackWalkReportsEnabled: false))
    XCTAssertTrue(OutboxRules.needsSend(capture, trackWalkReportsEnabled: true))
    OutboxRules.apply(.transientFailure("offline"), to: &capture)
    XCTAssertFalse(OutboxRules.needsSend(capture, trackWalkReportsEnabled: false))
  }

  func testRaceIgnoresTrackWalkGate() {
    XCTAssertTrue(OutboxRules.needsSend(race(), trackWalkReportsEnabled: false))
  }

  func testTrackWalkRoundTripKeepsVideoFields() throws {
    var capture = walk()
    OutboxRules.markRecorded(&capture, videoFileName: "a.mp4", savedToPhotos: false)
    XCTAssertEqual(try OutboxCoding.decode(OutboxCoding.encode([capture])), [capture])
  }

  func testDecodesManifestWithoutTrackWalkFields() throws {
    let json = #"""
    {"captures":[{"attempts":0,"createdAt":"2023-11-14T22:13:20Z","durationMin":12,"id":"11111111-2222-3333-4444-555555555555","mode":"race","retryable":true,"scoutContext":"Driver Stand","sessionId":"s","state":"reportPending","trackName":"t","transcript":[],"vehicleModel":"Nitro Buggy"}],"version":1}
    """#
    let captures = try OutboxCoding.decode(Data(json.utf8))
    XCTAssertEqual(captures.count, 1)
    XCTAssertNil(captures[0].videoFileName)
    XCTAssertNil(captures[0].noNarration)
  }
}
