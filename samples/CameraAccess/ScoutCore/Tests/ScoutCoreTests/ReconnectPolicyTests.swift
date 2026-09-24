import XCTest
@testable import ScoutCore

final class ReconnectPolicyTests: XCTestCase {
  func testFirstAttemptIsImmediate() {
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 0), 0)
  }

  func testBackoffDoublesAfterEachFailure() {
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 1), 1)
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 2), 2)
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 3), 4)
    XCTAssertEqual(ReconnectPolicy.delay(afterConsecutiveFailures: 4), 8)
  }

  func testGivesUpAfterFiveFailures() {
    XCTAssertNil(ReconnectPolicy.delay(afterConsecutiveFailures: 5))
    XCTAssertNil(ReconnectPolicy.delay(afterConsecutiveFailures: 50))
  }

  func testNegativeFailureCountGivesUp() {
    XCTAssertNil(ReconnectPolicy.delay(afterConsecutiveFailures: -1))
  }

  func testHandleIsDroppedAfterTwoFailedResumes() {
    XCTAssertEqual(ReconnectPolicy.dropHandleAfterFailures, 2)
  }
}
