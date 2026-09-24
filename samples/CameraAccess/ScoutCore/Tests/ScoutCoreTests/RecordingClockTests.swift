import XCTest
@testable import ScoutCore

final class RecordingClockTests: XCTestCase {
  func testNothingBeforeStart() {
    let clock = RecordingClock()
    XCTAssertFalse(clock.isStarted)
    XCTAssertNil(clock.mediaTime(for: 10))
    XCTAssertEqual(clock.elapsed(at: 10), 0)
  }

  func testMediaTimeCountsFromStart() {
    var clock = RecordingClock()
    clock.start(at: 100)
    XCTAssertEqual(clock.mediaTime(for: 100), 0)
    XCTAssertEqual(clock.mediaTime(for: 102.5), 2.5)
    XCTAssertNil(clock.mediaTime(for: 99))
    XCTAssertEqual(clock.elapsed(at: 110), 10)
  }

  func testPauseCutsTimeOut() {
    var clock = RecordingClock()
    clock.start(at: 100)
    clock.pause(at: 110)
    XCTAssertTrue(clock.isPaused)
    XCTAssertNil(clock.mediaTime(for: 112))
    XCTAssertEqual(clock.elapsed(at: 130), 10)
    clock.resume(at: 130)
    XCTAssertFalse(clock.isPaused)
    XCTAssertEqual(clock.mediaTime(for: 131), 11)
    XCTAssertEqual(clock.elapsed(at: 140), 20)
  }

  func testSampleFromInsideAPauseIsDropped() {
    var clock = RecordingClock()
    clock.start(at: 0)
    clock.pause(at: 10)
    clock.resume(at: 20)
    // Captured at 15 (while paused) but delivered after resume.
    XCTAssertNil(clock.mediaTime(for: 15))
    XCTAssertEqual(clock.mediaTime(for: 20), 10)
  }

  func testRepeatedCallsAreIgnored() {
    var clock = RecordingClock()
    clock.start(at: 0)
    clock.start(at: 50)
    clock.pause(at: 10)
    clock.pause(at: 12)
    clock.resume(at: 20)
    clock.resume(at: 25)
    XCTAssertEqual(clock.elapsed(at: 30), 20)
  }
}
