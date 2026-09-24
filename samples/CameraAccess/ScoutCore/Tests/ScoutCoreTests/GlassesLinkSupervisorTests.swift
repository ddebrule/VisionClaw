import XCTest
@testable import ScoutCore

final class GlassesLinkSupervisorTests: XCTestCase {
  private func streamingSupervisor() -> GlassesLinkSupervisor {
    var link = GlassesLinkSupervisor()
    _ = link.handle(.userStarted)
    _ = link.handle(.streaming)
    return link
  }

  private func waitingSupervisor() -> GlassesLinkSupervisor {
    var link = streamingSupervisor()
    _ = link.handle(.dropped(reconnectAllowed: true))
    return link
  }

  func testStartThenStreaming() {
    var link = GlassesLinkSupervisor()
    XCTAssertEqual(link.handle(.userStarted), .none)
    XCTAssertEqual(link.phase, .connecting)
    XCTAssertEqual(link.handle(.streaming), .none)
    XCTAssertEqual(link.phase, .streaming)
    XCTAssertFalse(link.isRecovering)
  }

  func testDropDuringScoutSchedulesRetry() {
    var link = streamingSupervisor()
    XCTAssertEqual(link.handle(.dropped(reconnectAllowed: true)), .scheduleRetry(after: 1.5))
    XCTAssertEqual(link.phase, .waitingToRetry)
    XCTAssertTrue(link.isRecovering)
  }

  func testDropWithoutScoutStops() {
    var link = streamingSupervisor()
    XCTAssertEqual(link.handle(.dropped(reconnectAllowed: false)), .stop)
    XCTAssertEqual(link.phase, .idle)
    XCTAssertFalse(link.isRecovering)
  }

  func testDropWhileConnectingDuringScoutSchedulesRetry() {
    var link = GlassesLinkSupervisor()
    _ = link.handle(.userStarted)
    XCTAssertEqual(link.handle(.dropped(reconnectAllowed: true)), .scheduleRetry(after: 1.5))
  }

  func testSecondDropWhileWaitingDoesNotStackRetries() {
    var link = waitingSupervisor()
    XCTAssertEqual(link.handle(.dropped(reconnectAllowed: true)), .none)
    XCTAssertEqual(link.phase, .waitingToRetry)
  }

  func testRetryFiredStartsAttempt() {
    var link = waitingSupervisor()
    XCTAssertEqual(link.handle(.retryFired(reconnectAllowed: true)), .retryNow)
    XCTAssertEqual(link.phase, .connecting)
    XCTAssertTrue(link.isRecovering)
  }

  func testFailedAttemptSchedulesAnotherRetry() {
    var link = waitingSupervisor()
    _ = link.handle(.retryFired(reconnectAllowed: true))
    XCTAssertEqual(link.handle(.dropped(reconnectAllowed: true)), .scheduleRetry(after: 1.5))
  }

  func testStreamingAfterRetryClearsRecovering() {
    var link = waitingSupervisor()
    _ = link.handle(.retryFired(reconnectAllowed: true))
    XCTAssertEqual(link.handle(.streaming), .none)
    XCTAssertEqual(link.phase, .streaming)
    XCTAssertFalse(link.isRecovering)
  }

  func testRetryFiredAfterScoutEndedStops() {
    var link = waitingSupervisor()
    XCTAssertEqual(link.handle(.retryFired(reconnectAllowed: false)), .stop)
    XCTAssertEqual(link.phase, .idle)
  }

  func testDropWhileWaitingAfterScoutEndedStops() {
    var link = waitingSupervisor()
    XCTAssertEqual(link.handle(.dropped(reconnectAllowed: false)), .stop)
    XCTAssertEqual(link.phase, .idle)
  }

  func testUserStopDuringWaitIgnoresLateRetry() {
    var link = waitingSupervisor()
    XCTAssertEqual(link.handle(.stopped), .none)
    XCTAssertEqual(link.phase, .idle)
    XCTAssertFalse(link.isRecovering)
    XCTAssertEqual(link.handle(.retryFired(reconnectAllowed: true)), .none)
    XCTAssertEqual(link.phase, .idle)
  }

  func testDropWhenIdleIsIgnored() {
    var link = GlassesLinkSupervisor()
    XCTAssertEqual(link.handle(.dropped(reconnectAllowed: true)), .none)
    XCTAssertEqual(link.phase, .idle)
  }

  func testStreamingWhenIdleIsIgnored() {
    var link = GlassesLinkSupervisor()
    XCTAssertEqual(link.handle(.streaming), .none)
    XCTAssertEqual(link.phase, .idle)
  }

  func testRetriesContinueIndefinitely() {
    var link = waitingSupervisor()
    for _ in 0..<1_000 {
      XCTAssertEqual(link.handle(.retryFired(reconnectAllowed: true)), .retryNow)
      XCTAssertEqual(link.handle(.dropped(reconnectAllowed: true)), .scheduleRetry(after: 1.5))
    }
    XCTAssertEqual(link.phase, .waitingToRetry)
  }

  func testConstants() {
    XCTAssertEqual(GlassesLinkSupervisor.retryInterval, 1.5)
    XCTAssertEqual(GlassesLinkSupervisor.attemptTimeout, 10)
  }
}
