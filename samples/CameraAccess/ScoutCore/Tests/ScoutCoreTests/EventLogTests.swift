import XCTest
@testable import ScoutCore

final class EventLogTests: XCTestCase {
  func testAppendKeepsOldestFirst() {
    var log = EventLog(capacity: 10)
    log.append("a", at: Date(timeIntervalSince1970: 0))
    log.append("b", at: Date(timeIntervalSince1970: 1))
    XCTAssertEqual(log.entries.map(\.text), ["a", "b"])
    XCTAssertEqual(log.entries.map(\.id), [0, 1])
  }

  func testDropsOldestWhenFull() {
    var log = EventLog(capacity: 3)
    for text in ["a", "b", "c", "d", "e"] { log.append(text) }
    XCTAssertEqual(log.entries.map(\.text), ["c", "d", "e"])
    XCTAssertEqual(log.entries.map(\.id), [2, 3, 4])
  }

  func testStaysCappedOverManyAppends() {
    var log = EventLog(capacity: 500)
    for index in 0..<5_000 { log.append("event \(index)") }
    XCTAssertEqual(log.entries.count, 500)
    XCTAssertEqual(log.entries.first?.text, "event 4500")
    XCTAssertEqual(log.entries.last?.text, "event 4999")
  }

  func testClearEmptiesButIDsKeepIncreasing() {
    var log = EventLog(capacity: 10)
    log.append("a")
    log.clear()
    XCTAssertTrue(log.entries.isEmpty)
    log.append("b")
    XCTAssertEqual(log.entries.map(\.id), [1])
  }

  func testExportFormatsOneLinePerEntry() {
    var log = EventLog(capacity: 10)
    log.append("session state: started", at: Date(timeIntervalSince1970: 0))
    log.append("stream error: hingesClosed", at: Date(timeIntervalSince1970: 61.5))
    let utc = TimeZone(identifier: "UTC")!
    XCTAssertEqual(
      log.exportText(timeZone: utc),
      "00:00:00.000  session state: started\n00:01:01.500  stream error: hingesClosed")
  }

  func testExportOfEmptyLogIsEmptyString() {
    XCTAssertEqual(EventLog(capacity: 10).exportText(), "")
  }
}
