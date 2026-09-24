import UIKit
import WebRTC

/// Bridges pixel-buffer frames from DAT SDK / iPhone camera into WebRTC's video pipeline.
/// Creates RTCVideoFrame from UIImage and feeds it to RTCVideoSource via the capturer delegate pattern.
class CustomVideoCapturer: RTCVideoCapturer {
  private var frameCount: Int64 = 0

  /// Push one frame into the WebRTC video track. Frames arrive as BGRA pixel
  /// buffers straight from the FrameHub, so there is no UIImage round trip.
  func pushFrame(_ pixelBuffer: CVPixelBuffer) {
    let rtcPixelBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
    let timeStampNs = Int64(CACurrentMediaTime() * 1_000_000_000)
    let rtcFrame = RTCVideoFrame(
      buffer: rtcPixelBuffer,
      rotation: ._0,
      timeStampNs: timeStampNs
    )

    self.delegate?.capturer(self, didCapture: rtcFrame)

    frameCount += 1
    if frameCount == 1 || frameCount % 120 == 0 {
      NSLog("[WebRTC] Pushed frame #%lld (%dx%d)", frameCount,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
    }
  }
}
