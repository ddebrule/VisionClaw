import XCTest
@testable import ScoutCore

final class FrameThrottleTests: XCTestCase {
  func testFirstFramePasses() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
  }

  func testBlocksWithinTheInterval() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    XCTAssertFalse(throttle.shouldPass(at: 100.5))
    XCTAssertFalse(throttle.shouldPass(at: 100.999))
  }

  func testPassesAtExactlyTheInterval() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    XCTAssertTrue(throttle.shouldPass(at: 101))
    XCTAssertFalse(throttle.shouldPass(at: 101.5))
    XCTAssertTrue(throttle.shouldPass(at: 102))
  }

  func testBlockedFramesDoNotMoveTheWindow() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 0))
    for step in 1...9 {
      XCTAssertFalse(throttle.shouldPass(at: Double(step) / 10))
    }
    XCTAssertTrue(throttle.shouldPass(at: 1.0))
  }

  func testEightPerSecondFromThirtyFrames() {
    var throttle = FrameThrottle(minimumInterval: 1.0 / 8)
    let passed = (0..<30).filter { throttle.shouldPass(at: Double($0) / 30) }.count
    XCTAssertEqual(passed, 8)
  }

  func testClockGoingBackwardsPasses() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    XCTAssertTrue(throttle.shouldPass(at: 50))
    XCTAssertFalse(throttle.shouldPass(at: 50.5))
  }

  func testResetLetsTheNextFrameThrough() {
    var throttle = FrameThrottle(minimumInterval: 1)
    XCTAssertTrue(throttle.shouldPass(at: 100))
    throttle.reset()
    XCTAssertTrue(throttle.shouldPass(at: 100.1))
  }

  func testZeroIntervalPassesEverything() {
    var throttle = FrameThrottle(minimumInterval: 0)
    XCTAssertTrue(throttle.shouldPass(at: 1))
    XCTAssertTrue(throttle.shouldPass(at: 1))
  }
}
