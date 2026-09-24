import CoreMedia
import CoreVideo
import Foundation

/// One video frame from any source: the glasses (raw or decoded) or the phone camera.
struct VideoFrameSample {
  let pixelBuffer: CVPixelBuffer
  let timestamp: CMTime
}

/// Fans each frame out to its subscribers. Every source publishes a frame once;
/// each consumer (preview, Gemini, WebRTC, and later the Track Walk recorder)
/// subscribes and applies its own rate. Subscribers run on the main actor and
/// must return quickly: anything expensive goes to a background queue.
@MainActor
final class FrameHub {
  typealias Subscriber = (VideoFrameSample) -> Void

  private var subscribers: [UUID: Subscriber] = [:]

  @discardableResult
  func subscribe(_ subscriber: @escaping Subscriber) -> UUID {
    let id = UUID()
    subscribers[id] = subscriber
    return id
  }

  func unsubscribe(_ id: UUID) {
    subscribers[id] = nil
  }

  func publish(_ frame: VideoFrameSample) {
    for subscriber in subscribers.values {
      subscriber(frame)
    }
  }
}
