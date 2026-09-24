import Foundation

/// A fixed-size, oldest-first log of timestamped lines. When full, the oldest
/// line is dropped, so a long session cannot grow it without bound.
public struct EventLog: Equatable, Sendable {
  public struct Entry: Equatable, Identifiable, Sendable {
    public let id: Int
    public let date: Date
    public let text: String
  }

  public let capacity: Int
  public private(set) var entries: [Entry] = []
  private var nextID = 0

  public init(capacity: Int) {
    precondition(capacity > 0, "EventLog capacity must be positive")
    self.capacity = capacity
  }

  public mutating func append(_ text: String, at date: Date = Date()) {
    entries.append(Entry(id: nextID, date: date, text: text))
    nextID += 1
    if entries.count > capacity {
      entries.removeFirst(entries.count - capacity)
    }
  }

  public mutating func clear() {
    entries.removeAll()
  }

  /// One line per entry, oldest first: `HH:mm:ss.SSS  text`.
  public func exportText(timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm:ss.SSS"
    return entries
      .map { "\(formatter.string(from: $0.date))  \($0.text)" }
      .joined(separator: "\n")
  }
}
