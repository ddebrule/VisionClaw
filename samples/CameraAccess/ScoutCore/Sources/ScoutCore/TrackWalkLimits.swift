import Foundation

/// Track Walk timing, storage and quality limits (spec §B4). SPECTRE refuses
/// walks over 15:00, so recording stops at 14:55.
public enum TrackWalkLimits {
  public static let warnAt: TimeInterval = 12 * 60 + 55
  public static let stopAt: TimeInterval = 14 * 60 + 55
  /// Folded or paused this long, and the walk finishes.
  public static let pausedFinishAfter: TimeInterval = 120
  public static let minFreeBytesToStart: Int64 = 3_000_000_000
  public static let minFreeBytesWhileRecording: Int64 = 300_000_000

  public enum Cue: Equatable, Sendable {
    case none
    case twoMinutesLeft
    case stop
  }

  public static func cue(elapsed: TimeInterval, warned: Bool) -> Cue {
    if elapsed >= stopAt { return .stop }
    if elapsed >= warnAt && !warned { return .twoMinutesLeft }
    return .none
  }

  /// About 10 Mbps for 1080p, scaled by pixel count, never below 2 Mbps.
  public static func videoBitRate(width: Int, height: Int) -> Int {
    let scaled = 10_000_000.0 * Double(width * height) / Double(1920 * 1080)
    return max(2_000_000, Int(scaled))
  }
}
