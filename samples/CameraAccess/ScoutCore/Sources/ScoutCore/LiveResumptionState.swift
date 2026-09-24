import Foundation

/// The latest Gemini Live session-resumption handle.
///
/// The server sends `sessionResumptionUpdate { newHandle, resumable }` during a
/// session; passing the last resumable handle in the next connection's
/// `setup.sessionResumption.handle` continues the same conversation. Handles
/// stay valid for 2 hours after the connection ends.
struct LiveResumptionState: Equatable {
  private(set) var handle: String?

  mutating func apply(update: [String: Any]) {
    guard update["resumable"] as? Bool == true,
          let newHandle = update["newHandle"] as? String, !newHandle.isEmpty
    else { return }
    handle = newHandle
  }

  /// Value for `setup.sessionResumption`. Empty on a first connection, which
  /// still opts the session into receiving resumption updates.
  var setupField: [String: Any] {
    guard let handle else { return [:] }
    return ["handle": handle]
  }

  mutating func reset() {
    handle = nil
  }
}
