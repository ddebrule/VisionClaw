import Foundation

/// Lets a frame through when at least `minimumInterval` seconds have passed
/// since the last frame it let through. Blocked frames do not move the window,
/// and a clock that goes backwards restarts it.
public struct FrameThrottle: Equatable, Sendable {
  public let minimumInterval: TimeInterval
  private var lastPassed: TimeInterval?

  public init(minimumInterval: TimeInterval) {
    self.minimumInterval = minimumInterval
  }

  public mutating func shouldPass(at now: TimeInterval) -> Bool {
    if let lastPassed, now >= lastPassed, now - lastPassed < minimumInterval {
      return false
    }
    lastPassed = now
    return true
  }

  public mutating func reset() {
    lastPassed = nil
  }
}
