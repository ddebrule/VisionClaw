import Foundation

public enum IdleGuardAction: Equatable, Sendable {
  case none
  /// Say "Scout still running" (once per silence stretch).
  case warn
  /// End the Race and send the report.
  case end
}

/// Race silence rule: warn after 30 minutes with no speech, end after 45.
public struct IdleGuard: Equatable, Sendable {
  public static let warnAfter: TimeInterval = 30 * 60
  public static let endAfter: TimeInterval = 45 * 60

  private var lastActivity: TimeInterval
  private var warned = false

  public init(now: TimeInterval) {
    lastActivity = now
  }

  public mutating func noteActivity(at now: TimeInterval) {
    lastActivity = now
    warned = false
  }

  public mutating func check(at now: TimeInterval) -> IdleGuardAction {
    let silence = now - lastActivity
    if silence >= Self.endAfter { return .end }
    if silence >= Self.warnAfter, !warned {
      warned = true
      return .warn
    }
    return .none
  }
}
