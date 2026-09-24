import XCTest
@testable import ScoutCore

final class TrackWalkLimitsTests: XCTestCase {
  func testConstants() {
    XCTAssertEqual(TrackWalkLimits.warnAt, 775)
    XCTAssertEqual(TrackWalkLimits.stopAt, 895)
    XCTAssertEqual(TrackWalkLimits.pausedFinishAfter, 120)
    XCTAssertEqual(TrackWalkLimits.minFreeBytesToStart, 3_000_000_000)
    XCTAssertEqual(TrackWalkLimits.minFreeBytesWhileRecording, 300_000_000)
  }

  func testCues() {
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 774, warned: false), .none)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 775, warned: false), .twoMinutesLeft)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 800, warned: true), .none)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 895, warned: true), .stop)
    XCTAssertEqual(TrackWalkLimits.cue(elapsed: 900, warned: false), .stop)
  }

  func testBitRateScalesByPixels() {
    XCTAssertEqual(TrackWalkLimits.videoBitRate(width: 1080, height: 1920), 10_000_000)
    XCTAssertEqual(TrackWalkLimits.videoBitRate(width: 720, height: 1280), 4_444_444)
    XCTAssertEqual(TrackWalkLimits.videoBitRate(width: 360, height: 640), 2_000_000)
  }
}
