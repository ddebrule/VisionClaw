import AVFoundation
import CoreVideo
import Foundation

/// Writes a Track Walk to a fragmented QuickTime .mov (crash-safe: at most
/// the last 2 s is lost). Video frames come from the FrameHub (stamped with
/// host time on arrival); audio comes from its own capture session, which is
/// told not to touch the app's audio session so the glasses route holds.
/// Everything that touches the writer runs on `queue` (a dispatch queue,
/// because the audio data output delivers its callbacks on one). Starting and
/// stopping the capture session runs on `sessionQueue`, so `queue` never blocks
/// on `startRunning()` and a stop can never overtake a queued start.
final class TrackWalkRecorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
  /// Called on the main thread, once, when the writer fails mid-recording.
  var onFailure: ((String) -> Void)?

  private let outputURL: URL
  private let queue = DispatchQueue(label: "trackwalk-writer")
  private let sessionQueue = DispatchQueue(label: "trackwalk-capture-session")
  private let audioSession = AVCaptureSession()
  private let audioOutput = AVCaptureAudioDataOutput()

  private var writer: AVAssetWriter?
  private var videoInput: AVAssetWriterInput?
  private var audioInput: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var clock = RecordingClock()
  private var lastVideoTime: TimeInterval = -1
  private var lastAudioTime: TimeInterval = -1
  private var finished = false
  private var reportedFailure = false
  private var loggedAppendFailure = false

  init(outputURL: URL) {
    self.outputURL = outputURL
    super.init()
  }

  /// Starts the microphone. The writer is created on the first video frame,
  /// when the frame size is known.
  func start() throws {
    audioSession.automaticallyConfiguresApplicationAudioSession = false
    audioSession.beginConfiguration()
    guard let mic = AVCaptureDevice.default(for: .audio) else {
      audioSession.commitConfiguration()
      throw CocoaError(.featureUnsupported)
    }
    let input = try AVCaptureDeviceInput(device: mic)
    if audioSession.canAddInput(input) { audioSession.addInput(input) }
    audioOutput.setSampleBufferDelegate(self, queue: queue)
    if audioSession.canAddOutput(audioOutput) { audioSession.addOutput(audioOutput) }
    audioSession.commitConfiguration()
    sessionQueue.async { [audioSession] in audioSession.startRunning() }
  }

  func appendVideo(_ pixelBuffer: CVPixelBuffer, hostTime: TimeInterval) {
    queue.async { [self] in
      guard !finished else { return }
      if writer == nil {
        makeWriter(
          width: CVPixelBufferGetWidth(pixelBuffer),
          height: CVPixelBufferGetHeight(pixelBuffer),
          startTime: hostTime)
      }
      guard !writerFailed() else { return }
      guard let videoInput, let adaptor, videoInput.isReadyForMoreMediaData,
            let media = clock.mediaTime(for: hostTime), media > lastVideoTime
      else { return }
      if adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: media, preferredTimescale: 600)) {
        lastVideoTime = media
      } else {
        logAppendFailure("video")
      }
    }
  }

  func pause(at hostTime: TimeInterval) {
    queue.async { [self] in clock.pause(at: hostTime) }
  }

  func resume(at hostTime: TimeInterval) {
    queue.async { [self] in clock.resume(at: hostTime) }
  }

  /// Recorded time so far (pauses excluded). Never call this from `queue`.
  func elapsed(at hostTime: TimeInterval) -> TimeInterval {
    queue.sync { clock.elapsed(at: hostTime) }
  }

  /// Stops capture and closes the file. True when a playable file was written.
  func finish() async -> Bool {
    await withCheckedContinuation { continuation in
      // Same serial queue as the start, so this stop runs after it; then the writer queue.
      sessionQueue.async { [self] in
        audioSession.stopRunning()
        queue.async { [self] in
          finished = true
          guard let writer, writer.status == .writing else {
            continuation.resume(returning: false)
            return
          }
          videoInput?.markAsFinished()
          audioInput?.markAsFinished()
          writer.finishWriting {
            continuation.resume(returning: writer.status == .completed)
          }
        }
      }
    }
  }

  // MARK: - Audio

  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    // Already on `queue`.
    guard !finished, !writerFailed(), let audioInput, audioInput.isReadyForMoreMediaData else { return }
    // Audio is stamped on the capture session's clock; video on host time (CACurrentMediaTime).
    let hostClock = CMClockGetHostTimeClock()
    let hostTime = CMSyncConvertTime(
      CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
      from: audioSession.synchronizationClock ?? hostClock,
      to: hostClock
    ).seconds
    guard let media = clock.mediaTime(for: hostTime), media > lastAudioTime else { return }
    // Keep the buffer's own per-sample duration; only move its start time.
    var timing = CMSampleTimingInfo()
    guard CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timing) == noErr else { return }
    timing.presentationTimeStamp = CMTime(seconds: media, preferredTimescale: 48_000)
    timing.decodeTimeStamp = .invalid
    var copy: CMSampleBuffer?
    guard CMSampleBufferCreateCopyWithNewTiming(
      allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
      sampleTimingEntryCount: 1, sampleTimingArray: &timing,
      sampleBufferOut: &copy) == noErr, let retimed = copy
    else { return }
    if audioInput.append(retimed) {
      lastAudioTime = media
    } else {
      logAppendFailure("audio")
    }
  }

  // MARK: - Writer

  /// True once the writer has failed; logs and reports it the first time. On `queue`.
  private func writerFailed() -> Bool {
    guard let writer, writer.status == .failed else { return false }
    if !reportedFailure {
      reportedFailure = true
      let message = writer.error?.localizedDescription ?? "unknown"
      NSLog("[TrackWalk] Writer failed: %@", message)
      let onFailure = onFailure
      DispatchQueue.main.async { onFailure?(message) }
    }
    return true
  }

  /// Logs the first rejected append only. On `queue`.
  private func logAppendFailure(_ track: String) {
    guard !loggedAppendFailure else { return }
    loggedAppendFailure = true
    NSLog("[TrackWalk] %@ append failed (writer status %ld): %@",
          track, writer?.status.rawValue ?? -1, writer?.error?.localizedDescription ?? "none")
  }

  private func makeWriter(width: Int, height: Int, startTime: TimeInterval) {
    do {
      try? FileManager.default.removeItem(at: outputURL)
      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
      writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)

      let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: TrackWalkLimits.videoBitRate(width: width, height: height),
          AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        ],
      ])
      video.expectsMediaDataInRealTime = true
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)

      let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVNumberOfChannelsKey: 1,
        AVSampleRateKey: 44_100,
        AVEncoderBitRateKey: 64_000,
      ])
      audio.expectsMediaDataInRealTime = true

      if writer.canAdd(video) { writer.add(video) }
      if writer.canAdd(audio) { writer.add(audio) }
      guard writer.startWriting() else {
        NSLog("[TrackWalk] Writer failed to start: %@", writer.error?.localizedDescription ?? "unknown")
        return
      }
      writer.startSession(atSourceTime: .zero)
      clock.start(at: startTime)
      self.writer = writer
      self.videoInput = video
      self.audioInput = audio
      self.adaptor = adaptor
      NSLog("[TrackWalk] Recording %ldx%ld to %@", width, height, outputURL.lastPathComponent)
    } catch {
      NSLog("[TrackWalk] Writer setup failed: %@", error.localizedDescription)
    }
  }
}
