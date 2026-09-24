import AVFoundation
import SwiftUI

/// Native preview for iPhone mode.
///
/// The frames sent to the model still go through the FrameHub, but the picture
/// on screen comes straight off the capture session: AVCaptureVideoPreviewLayer
/// composites in hardware at the sensor's own resolution, so there is no
/// UIImage and no upscaling.
struct IPhoneCameraPreviewView: UIViewRepresentable {
  let session: AVCaptureSession

  func makeUIView(context: Context) -> PreviewUIView {
    let view = PreviewUIView()
    view.previewLayer.session = session
    view.previewLayer.videoGravity = .resizeAspectFill
    return view
  }

  func updateUIView(_ view: PreviewUIView, context: Context) {
    if view.previewLayer.session !== session {
      view.previewLayer.session = session
    }
  }

  final class PreviewUIView: UIView {
    override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
}
