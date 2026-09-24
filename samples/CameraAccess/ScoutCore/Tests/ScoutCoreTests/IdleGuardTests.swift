import XCTest
@testable import ScoutCore

final class IdleGuardTests: XCTestCase {
  func testQuietBeforeThirtyMinutes() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 29 * 60), .none)
  }

  func testWarnsOnceAtThirtyMinutes() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 30 * 60), .warn)
    XCTAssertEqual(idle.check(at: 31 * 60), .none)
  }

  func testEndsAfterFortyFiveMinutes() {
    var idle = IdleGuard(now: 0)
    _ = idle.check(at: 30 * 60)
    XCTAssertEqual(idle.check(at: 45 * 60), .end)
  }

  func testEndsEvenIfWarningWasMissed() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 50 * 60), .end)
  }

  func testActivityResetsTheClockAndTheWarning() {
    var idle = IdleGuard(now: 0)
    XCTAssertEqual(idle.check(at: 30 * 60), .warn)
    idle.noteActivity(at: 40 * 60)
    XCTAssertEqual(idle.check(at: 69 * 60), .none)
    XCTAssertEqual(idle.check(at: 70 * 60), .warn)
    XCTAssertEqual(idle.check(at: 85 * 60), .end)
  }

  func testConstants() {
    XCTAssertEqual(IdleGuard.warnAfter, 1800)
    XCTAssertEqual(IdleGuard.endAfter, 2700)
  }
}
