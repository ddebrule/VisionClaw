import Foundation

/// Pause-aware recording time. Host-clock seconds go in; media time (seconds
/// since the start, with every pause cut out) comes out. Samples captured
/// during a pause have no media time and are dropped.
public struct RecordingClock: Equatable, Sendable {
  private var startedAt: TimeInterval?
  private var pausedAt: TimeInterval?
  private var pausedTotal: TimeInterval = 0
  private var pauses: [ClosedRange<TimeInterval>] = []

  public init() {}

  public var isStarted: Bool { startedAt != nil }
  public var isPaused: Bool { pausedAt != nil }

  public mutating func start(at time: TimeInterval) {
    guard startedAt == nil else { return }
    startedAt = time
  }

  public mutating func pause(at time: TimeInterval) {
    guard startedAt != nil, pausedAt == nil else { return }
    pausedAt = time
  }

  public mutating func resume(at time: TimeInterval) {
    guard let pausedAt else { return }
    pausedTotal += time - pausedAt
    pauses.append(pausedAt...time)
    self.pausedAt = nil
  }

  public func mediaTime(for time: TimeInterval) -> TimeInterval? {
    guard let startedAt, time >= startedAt else { return nil }
    if let pausedAt, time >= pausedAt { return nil }
    var cut: TimeInterval = 0
    for pause in pauses {
      if pause.contains(time) && time < pause.upperBound { return nil }
      if time >= pause.upperBound { cut += pause.upperBound - pause.lowerBound }
    }
    return time - startedAt - cut
  }

  public func elapsed(at now: TimeInterval) -> TimeInterval {
    guard let startedAt else { return 0 }
    let end = pausedAt ?? now
    return max(0, end - startedAt - pausedTotal)
  }
}
