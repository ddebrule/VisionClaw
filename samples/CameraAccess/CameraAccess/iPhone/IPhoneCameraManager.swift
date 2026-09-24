import AVFoundation
import UIKit

class IPhoneCameraManager: NSObject {
  private let captureSession = AVCaptureSession()
  private let videoOutput = AVCaptureVideoDataOutput()
  private let sessionQueue = DispatchQueue(label: "iphone-camera-session")
  private var isRunning = false

  /// For AVCaptureVideoPreviewLayer: drawing the preview from the session is
  /// sharper and cheaper than displaying converted frames.
  var session: AVCaptureSession { captureSession }

  // MARK: - Zoom

  private var device: AVCaptureDevice?
  /// Beyond roughly this the wide-angle sensor is just upscaling, which costs
  /// detail rather than adding it.
  private let maxZoom: CGFloat = 8

  var maxAvailableZoom: CGFloat {
    guard let device else { return 1 }
    return min(device.activeFormat.videoMaxZoomFactor, maxZoom)
  }

  /// Zoom applied at the sensor, so it sharpens what is captured rather than
  /// enlarging a finished frame. The preview and the model's frames both follow it.
  func setZoom(_ factor: CGFloat) {
    guard let device else { return }
    let clamped = min(max(factor, 1), maxAvailableZoom)
    sessionQueue.async {
      do {
        try device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
      } catch {
        NSLog("[iPhoneCamera] Zoom failed: %@", error.localizedDescription)
      }
    }
  }

  /// Called on the capture queue for every frame; the FrameHub throttles per consumer.
  var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?

  func start() {
    guard !isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.configureSession()
      self?.captureSession.startRunning()
      self?.isRunning = true
    }
  }

  func stop() {
    guard isRunning else { return }
    sessionQueue.async { [weak self] in
      self?.captureSession.stopRunning()
      self?.isRunning = false
    }
  }

  private func configureSession() {
    captureSession.beginConfiguration()
    // 1920x1080 rather than .medium's 480x360: the preview layer shows it at
    // full quality, and the FrameHub throttles what reaches the CPU path.
    captureSession.sessionPreset =
      captureSession.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

    // Add back camera input
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
          let input = try? AVCaptureDeviceInput(device: camera) else {
      NSLog("[iPhoneCamera] Failed to access back camera")
      captureSession.commitConfiguration()
      return
    }

    if captureSession.canAddInput(input) {
      captureSession.addInput(input)
      device = camera
    }

    // Add video output
    videoOutput.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    videoOutput.setSampleBufferDelegate(self, queue: sessionQueue)
    videoOutput.alwaysDiscardsLateVideoFrames = true

    if captureSession.canAddOutput(videoOutput) {
      captureSession.addOutput(videoOutput)
    }

    // Force portrait-oriented frames from the sensor
    if let connection = videoOutput.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) {
        connection.videoRotationAngle = 90
      }
    }

    captureSession.commitConfiguration()
    NSLog("[iPhoneCamera] Session configured")
  }

  static func requestPermission() async -> Bool {
    let status = AVCaptureDevice.authorizationStatus(for: .video)
    switch status {
    case .authorized:
      return true
    case .notDetermined:
      return await AVCaptureDevice.requestAccess(for: .video)
    default:
      return false
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension IPhoneCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    onPixelBuffer?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
  }
}
