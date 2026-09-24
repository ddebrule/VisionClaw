import CoreImage
import CoreVideo
import UIKit

/// Renders pixel buffers to UIImages on a background queue. Uses a CPU
/// CIContext so it keeps working while the phone is locked, when iOS suspends
/// GPU rendering for background apps.
final class PixelBufferImageRenderer {
  private let queue = DispatchQueue(label: "frame-image-render", qos: .userInitiated)
  private let context = CIContext(options: [.useSoftwareRenderer: true])

  func render(_ pixelBuffer: CVPixelBuffer, completion: @escaping @MainActor (UIImage) -> Void) {
    queue.async { [context] in
      let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
      guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
      let image = UIImage(cgImage: cgImage)
      Task { @MainActor in
        completion(image)
      }
    }
  }
}
