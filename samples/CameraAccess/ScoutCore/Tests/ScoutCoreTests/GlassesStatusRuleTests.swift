import XCTest
@testable import ScoutCore

final class GlassesStatusRuleTests: XCTestCase {
  private func status(now: TimeInterval, lastFrameAt: TimeInterval?, hingesClosed: Bool = false) -> GlassesStatus {
    GlassesStatusRule.status(now: now, startedAt: 100, lastFrameAt: lastFrameAt, hingesClosed: hingesClosed)
  }

  func testConnectingDuringGrace() {
    XCTAssertEqual(status(now: 100, lastFrameAt: nil), .connecting)
    XCTAssertEqual(status(now: 105.9, lastFrameAt: nil), .connecting)
  }

  func testGraceExpiresWithoutFrames() {
    XCTAssertEqual(status(now: 106, lastFrameAt: nil), .putThemOn)
    XCTAssertEqual(status(now: 200, lastFrameAt: nil), .putThemOn)
  }

  func testFreshFrameIsLive() {
    XCTAssertEqual(status(now: 102, lastFrameAt: 101.5), .live)
    XCTAssertEqual(status(now: 103, lastFrameAt: 101.5), .live)
  }

  func testStaleFramesAfterStartShowPutThemOn() {
    XCTAssertEqual(status(now: 103.01, lastFrameAt: 101.5), .putThemOn)
  }

  func testStaleFramesInsideGraceStillShowPutThemOn() {
    // Frames started then stopped: the connecting grace only covers the first frame.
    XCTAssertEqual(status(now: 104, lastFrameAt: 101), .putThemOn)
  }

  func testFoldedWhenFlagSetAndNoFreshFrames() {
    XCTAssertEqual(status(now: 103, lastFrameAt: nil, hingesClosed: true), .folded)
    XCTAssertEqual(status(now: 110, lastFrameAt: 101, hingesClosed: true), .folded)
  }

  func testLiveFramesBeatFoldedFlag() {
    XCTAssertEqual(status(now: 110, lastFrameAt: 109.9, hingesClosed: true), .live)
  }

  func testConstants() {
    XCTAssertEqual(GlassesStatusRule.staleAfter, 1.5)
    XCTAssertEqual(GlassesStatusRule.connectingGrace, 6)
  }
}
