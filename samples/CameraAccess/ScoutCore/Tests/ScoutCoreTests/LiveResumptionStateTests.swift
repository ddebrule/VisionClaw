import XCTest
@testable import ScoutCore

final class LiveResumptionStateTests: XCTestCase {
  func testStartsWithoutHandleAndEmptySetupField() {
    let state = LiveResumptionState()
    XCTAssertNil(state.handle)
    XCTAssertTrue(state.setupField.isEmpty)
  }

  func testResumableUpdateStoresHandle() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "h-1", "resumable": true])
    XCTAssertEqual(state.handle, "h-1")
    XCTAssertEqual(state.setupField as? [String: String], ["handle": "h-1"])
  }

  func testNonResumableUpdateKeepsPreviousHandle() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "h-1", "resumable": true])
    state.apply(update: ["newHandle": "h-2", "resumable": false])
    XCTAssertEqual(state.handle, "h-1")
  }

  func testEmptyOrMissingHandleIsIgnored() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "", "resumable": true])
    state.apply(update: ["resumable": true])
    XCTAssertNil(state.handle)
  }

  func testResetClearsHandle() {
    var state = LiveResumptionState()
    state.apply(update: ["newHandle": "h-1", "resumable": true])
    state.reset()
    XCTAssertNil(state.handle)
    XCTAssertTrue(state.setupField.isEmpty)
  }
}
