import Foundation

/// What the glasses screen should say.
public enum GlassesStatus: Equatable, Sendable {
  /// Frames are arriving; show the video.
  case live
  /// Just started and no frame yet; show a spinner.
  case connecting
  /// No fresh frames: the glasses are off the face, folded, or out of reach.
  case putThemOn
  /// The glasses reported their hinges closed and frames have stopped.
  case folded
}

/// Decides the glasses status from the frame clock. A stream is stale after
/// `staleAfter` seconds without a frame; right after Start, a missing first
/// frame reads as connecting for up to `connectingGrace` seconds so a slow
/// Bluetooth start never flashes "put them on".
public enum GlassesStatusRule {
  public static let staleAfter: TimeInterval = 1.5
  public static let connectingGrace: TimeInterval = 6

  public static func status(
    now: TimeInterval,
    startedAt: TimeInterval,
    lastFrameAt: TimeInterval?,
    hingesClosed: Bool
  ) -> GlassesStatus {
    if let lastFrameAt, now - lastFrameAt <= staleAfter {
      return .live
    }
    if hingesClosed {
      return .folded
    }
    if lastFrameAt == nil, now - startedAt < connectingGrace {
      return .connecting
    }
    return .putThemOn
  }
}
