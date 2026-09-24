import Foundation

/// When to retry a dropped Gemini Live connection.
///
/// Google closes every Live connection after ~10 minutes (a `goAway` message),
/// and trackside signal drops often, so a Race session reconnects instead of
/// ending. Eight attempts span ~60 s before giving up.
enum ReconnectPolicy {
  static let delays: [TimeInterval] = [0, 1, 2, 4, 8, 15, 15, 15]

  /// A resumption handle the server keeps refusing is stale; after this many
  /// refusals (the socket opened but setup never completed) reconnect without it
  /// (a fresh Gemini session with the same instruction — the app's own transcript
  /// is unaffected).
  static let dropHandleAfterFailures = 2

  /// Delay before the next attempt, or nil to give up.
  static func delay(afterConsecutiveFailures failures: Int) -> TimeInterval? {
    guard failures >= 0, failures < delays.count else { return nil }
    return delays[failures]
  }
}
