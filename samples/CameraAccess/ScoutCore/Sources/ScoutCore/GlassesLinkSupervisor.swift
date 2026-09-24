import Foundation

/// Something that happened to the glasses link.
public enum GlassesLinkEvent: Equatable {
  case userStarted
  case streaming
  /// The stream or session ended without the user asking. `reconnectAllowed`
  /// is true while a Scout session is running.
  case dropped(reconnectAllowed: Bool)
  case retryFired(reconnectAllowed: Bool)
  /// Streaming was stopped (by the user, or after a `.stop` action).
  case stopped
}

/// What the view model should do next.
public enum GlassesLinkAction: Equatable {
  case none
  case scheduleRetry(after: TimeInterval)
  case retryNow
  case stop
}

/// Decides when to reconnect the glasses. While Scout runs, a drop keeps the
/// session alive and retries every `retryInterval` until frames return or the
/// user stops; with no Scout session, a drop ends streaming.
public struct GlassesLinkSupervisor: Equatable {
  public enum Phase: Equatable {
    case idle
    case connecting
    case streaming
    case waitingToRetry
  }

  public static let retryInterval: TimeInterval = 1.5
  /// A reconnect attempt that has not produced frames by now counts as failed.
  public static let attemptTimeout: TimeInterval = 10

  public private(set) var phase: Phase = .idle
  public private(set) var isRecovering = false

  public init() {}

  public mutating func handle(_ event: GlassesLinkEvent) -> GlassesLinkAction {
    switch event {
    case .userStarted:
      phase = .connecting
      isRecovering = false
      return .none

    case .streaming:
      guard phase != .idle else { return .none }
      phase = .streaming
      isRecovering = false
      return .none

    case .dropped(let reconnectAllowed):
      switch phase {
      case .idle:
        return .none
      case .waitingToRetry:
        return reconnectAllowed ? .none : stop()
      case .connecting, .streaming:
        guard reconnectAllowed else { return stop() }
        phase = .waitingToRetry
        isRecovering = true
        return .scheduleRetry(after: Self.retryInterval)
      }

    case .retryFired(let reconnectAllowed):
      guard phase == .waitingToRetry else { return .none }
      guard reconnectAllowed else { return stop() }
      phase = .connecting
      return .retryNow

    case .stopped:
      phase = .idle
      isRecovering = false
      return .none
    }
  }

  private mutating func stop() -> GlassesLinkAction {
    phase = .idle
    isRecovering = false
    return .stop
  }
}
