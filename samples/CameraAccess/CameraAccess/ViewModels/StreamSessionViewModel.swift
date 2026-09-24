/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamSessionViewModel.swift
//
// Streams video from Meta glasses with the DAT SDK 0.9 model: a DeviceSession
// (the link to the glasses) is created and started first, then a Camera is added
// to the started session and its Stream carries the frames. The iPhone camera
// path touches neither. Every SDK event is written to the glasses event log.
//

import CoreImage
import CoreMedia
import CoreVideo
import MWDATCamera
import MWDATCore
import SwiftUI
import VideoToolbox

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

enum StreamingMode {
  case glasses
  case iPhone
}

@MainActor
class StreamSessionViewModel: ObservableObject {
  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var hasActiveDevice: Bool = false
  @Published var streamingMode: StreamingMode = .glasses
  @Published var selectedResolution: StreamingResolution = .low
  @Published private(set) var isReconnectingGlasses = false

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  /// Reconnect only while a Scout session is running, or its report is still
  /// waiting to be sent (End lives on the streaming screen).
  private var keepGlassesAlive: Bool {
    guard let gemini = geminiSessionVM else { return false }
    return gemini.isGeminiActive || gemini.hasUnsentReport
  }

  var resolutionLabel: String {
    switch selectedResolution {
    case .low: return "360x640"
    case .medium: return "504x896"
    case .high: return "720x1280"
    @unknown default: return "Unknown"
    }
  }

  // Photo capture properties
  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false

  // Gemini Live integration
  var geminiSessionVM: GeminiSessionViewModel?

  // WebRTC Live streaming integration
  var webrtcSessionVM: WebRTCSessionViewModel?

  // The device session is the link to the glasses. The camera is added to it
  // once the session reports .started, and the camera's stream carries video.
  private var deviceSession: DeviceSession?
  private var camera: Camera?
  // True from the user's Start until their Stop. A stream or session that ends
  // while this is set was not asked for, so it is a drop.
  private var wantsStream = false
  // Bumped whenever a session or camera is replaced, so events still arriving
  // from a torn-down one are ignored.
  private var sessionGeneration = 0
  private var cameraGeneration = 0
  // A fresh session or stream may report .idle/.stopped before it has started;
  // only a stop after it started counts as a drop.
  private var sessionHasStarted = false
  private var streamHasStarted = false
  // Reconnect decisions (see GlassesLinkSupervisor); the view model only
  // carries out the actions.
  private var link = GlassesLinkSupervisor()
  private var retryTask: Task<Void, Never>?
  private var attemptWatchdog: Task<Void, Never>?
  private var sessionStateListenerToken: AnyListenerToken?
  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private let wearables: WearablesInterface
  private let deviceSelector: AutoDeviceSelector
  private var deviceMonitorTask: Task<Void, Never>?
  private var iPhoneCameraManager: IPhoneCameraManager?

  // CPU-based CIContext for rendering decoded pixel buffers in background
  private let cpuCIContext = CIContext(options: [.useSoftwareRenderer: true])
  // VideoDecoder for decompressing HEVC/H.264 frames in background
  private let videoDecoder = VideoDecoder()
  private var backgroundFrameCount = 0
  private var bgDiagLogged = false
  // Foreground frames converted to UIImage: every 3rd (8 fps of 24) unless WebRTC
  // is live and needs them all. makeUIImage is a GPU->CPU render on the main
  // thread; doing it 24x/s froze the app. Replaced by FrameHub in Stage 3.
  private var foregroundFrameCount = 0
  // Delivered-frame-rate reporting for the event log.
  private var loggedFirstFrame = false
  private var deliveredFrames = 0
  private var frameWindowStart = Date()

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    // Let the SDK auto-select from available devices
    let selector = AutoDeviceSelector(wearables: wearables)
    self.deviceSelector = selector

    // Monitor device availability
    deviceMonitorTask = Task { @MainActor in
      for await device in selector.activeDeviceStream() {
        self.hasActiveDevice = device != nil
        self.logEvent(device == nil ? "active device: none" : "active device: available")
      }
    }

    setupVideoDecoder()
  }

  private func setupVideoDecoder() {
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      Task { @MainActor [weak self] in
        guard let self else { return }
        let pixelBuffer = decodedFrame.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
          let image = UIImage(cgImage: cgImage)
          self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
          self.webrtcSessionVM?.pushVideoFrame(image)
          if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
            NSLog("[Stream] Background frame #%d decoded and forwarded (%dx%d)",
                  self.backgroundFrameCount, width, height)
          }
        }
      }
    }
  }

  /// Stores the resolution for the next stream. In 0.9 the configuration is
  /// applied when the camera is added, so this only takes effect when not streaming.
  func updateResolution(_ resolution: StreamingResolution) {
    guard !isStreaming else { return }
    selectedResolution = resolution
    NSLog("[Stream] Resolution changed to %@", resolutionLabel)
  }

  private func streamConfig() -> StreamConfiguration {
    StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: selectedResolution,
      frameRate: 24)
  }

  func handleStartStreaming() async {
    let permission = Permission.camera
    do {
      let status = try await wearables.checkPermissionStatus(permission)
      if status == .granted {
        await startSession()
        return
      }
      let requestStatus = try await wearables.requestPermission(permission)
      if requestStatus == .granted {
        await startSession()
        return
      }
      showError("Permission denied")
    } catch {
      logEvent("permission check failed: \(String(describing: error))")
      showError("Permission error: \(String(describing: error))")
    }
  }

  func startSession() async {
    _ = link.handle(.userStarted)
    connectGlasses()
  }

  /// Creates and starts the device session. The camera is added once the
  /// session reports .started (see handleSessionState).
  private func connectGlasses() {
    wantsStream = true
    if let session = deviceSession {
      if session.state == .started, camera == nil {
        beginStream()
      }
      return
    }
    sessionGeneration &+= 1
    let generation = sessionGeneration
    sessionHasStarted = false
    do {
      let session = try wearables.createSession(deviceSelector: deviceSelector)
      deviceSession = session
      // Subscribe before start() so no transition is missed.
      sessionStateListenerToken = session.statePublisher.listen { [weak self] state in
        Task { @MainActor [weak self] in
          guard let self, generation == self.sessionGeneration else { return }
          self.handleSessionState(state)
        }
      }
      streamingStatus = .waiting
      logEvent("session created, starting")
      try session.start()
    } catch {
      logEvent("session start failed: \(String(describing: error))")
      deviceSession = nil
      handleGlassesDrop(reason: "session start failed")
      if !keepGlassesAlive {
        showError("Couldn't reach the glasses. Make sure they're on, unfolded and connected.")
      }
    }
  }

  private func handleSessionState(_ state: DeviceSessionState) {
    logEvent("session state: \(state)")
    switch state {
    case .started:
      sessionHasStarted = true
      if wantsStream, camera == nil {
        beginStream()
      }
    case .starting:
      sessionHasStarted = true
      streamingStatus = .waiting
    case .stopping, .paused:
      sessionHasStarted = true
      streamingStatus = .waiting
    case .idle, .stopped:
      guard sessionHasStarted else { return }
      if wantsStream {
        handleGlassesDrop(reason: "session \(state)")
      } else {
        markStopped()
      }
    }
  }

  /// Adds a camera to the started session, wires its stream, then starts it.
  private func beginStream() {
    guard let session = deviceSession, session.state == .started else { return }
    cameraGeneration &+= 1
    let generation = cameraGeneration
    streamHasStarted = false
    loggedFirstFrame = false
    do {
      guard let newCamera = try session.addCamera(config: streamConfig()) else {
        logEvent("addCamera returned no camera")
        handleGlassesDrop(reason: "no camera")
        return
      }
      camera = newCamera
      // Subscribe before start() so no transition is missed.
      attachStreamListeners(to: newCamera.stream, generation: generation)
      // Meta's ordering rule: route the glasses mic and let it settle before
      // the camera stream starts, or audio can fail over to the phone.
      Task { @MainActor [weak self] in
        if GlassesAudioRoute.selectGlassesMicIfNeeded() {
          self?.logEvent("glasses mic selected; letting the route settle")
          try? await Task.sleep(for: GlassesAudioRoute.settleDelay)
        }
        guard let self, generation == self.cameraGeneration else { return }
        self.logEvent("camera added, starting stream")
        newCamera.stream.start()
      }
    } catch {
      logEvent("addCamera failed: \(String(describing: error))")
      handleGlassesDrop(reason: "addCamera failed")
    }
  }

  private func attachStreamListeners(to stream: MWDATCamera.Stream, generation: Int) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, generation == self.cameraGeneration else { return }
        self.updateStatusFromState(state)
      }
    }

    // Fires in the foreground and the background, so streaming continues
    // with the screen locked.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] videoFrame in
      Task { @MainActor [weak self] in
        guard let self, generation == self.cameraGeneration else { return }
        self.noteDeliveredFrame(videoFrame.sampleBuffer)

        let isInBackground = UIApplication.shared.applicationState == .background

        if !isInBackground {
          self.backgroundFrameCount = 0
          self.bgDiagLogged = false
          self.foregroundFrameCount &+= 1
          let webrtcNeedsEveryFrame = self.webrtcSessionVM?.isActive == true
          guard webrtcNeedsEveryFrame || (self.foregroundFrameCount - 1) % 3 == 0 else { return }
          if let image = videoFrame.makeUIImage() {
            self.currentVideoFrame = image
            if !self.hasReceivedFirstFrame {
              self.hasReceivedFirstFrame = true
            }
            self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
            self.webrtcSessionVM?.pushVideoFrame(image)
          }
        } else {
          // In background: makeUIImage() uses VideoToolbox GPU rendering which iOS suspends.
          // Instead, use our VideoDecoder (VTDecompressionSession) to decode compressed
          // frames into pixel buffers, then convert via CPU CIContext.
          self.backgroundFrameCount += 1

          let sampleBuffer = videoFrame.sampleBuffer
          let hasCompressedData = CMSampleBufferGetDataBuffer(sampleBuffer) != nil

          if hasCompressedData {
            do {
              try self.videoDecoder.decode(sampleBuffer)
            } catch {
              if self.backgroundFrameCount <= 5 || self.backgroundFrameCount % 120 == 0 {
                NSLog("[Stream] Background frame #%d decode error: %@",
                      self.backgroundFrameCount, String(describing: error))
              }
            }
          } else if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rect = CGRect(x: 0, y: 0, width: width, height: height)
            if let cgImage = self.cpuCIContext.createCGImage(ciImage, from: rect) {
              let image = UIImage(cgImage: cgImage)
              self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
              self.webrtcSessionVM?.pushVideoFrame(image)
            }
            self.videoDecoder.invalidateSession()
          }
        }
      }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, generation == self.cameraGeneration else { return }
        self.logEvent("stream error: \(String(describing: error))")
        // While Scout runs, reconnect handles glasses errors; alerts would
        // stack up with the phone in a pocket.
        guard !self.keepGlassesAlive else { return }
        let message: String
        switch error {
        case .deviceNotConnected, .deviceNotFound:
          // Not an error before the user has started streaming.
          guard self.streamingStatus != .stopped else { return }
          message = "Glasses disconnected. Check they're on and in range."
        case .hingesClosed:
          message = "The glasses were folded. Unfold them and try again."
        case .permissionDenied:
          message = "Camera permission denied. Grant it in the Meta AI app."
        default:
          message = "Glasses streaming error. Please try again."
        }
        if message != self.errorMessage {
          self.showError(message)
        }
      }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] photoData in
      Task { @MainActor [weak self] in
        guard let self, generation == self.cameraGeneration else { return }
        if let uiImage = UIImage(data: photoData.data) {
          self.capturedPhoto = uiImage
          self.showPhotoPreview = true
        }
      }
    }
  }

  private func updateStatusFromState(_ state: StreamState) {
    logEvent("stream state: \(state)")
    switch state {
    case .streaming:
      streamHasStarted = true
      streamingStatus = .streaming
      _ = link.handle(.streaming)
      attemptWatchdog?.cancel()
      if isReconnectingGlasses {
        logEvent("reconnected")
        isReconnectingGlasses = false
      }
    case .starting:
      streamHasStarted = true
      streamingStatus = .waiting
    case .waitingForDevice, .stopping, .paused:
      streamHasStarted = true
      streamingStatus = .waiting
    case .stopped:
      currentVideoFrame = nil
      guard streamHasStarted else { return }
      if wantsStream {
        handleGlassesDrop(reason: "stream stopped")
      } else {
        markStopped()
      }
    }
  }

  /// A stream or session ended that the user did not stop. While Scout runs,
  /// the glasses are reconnected; otherwise streaming ends.
  private func handleGlassesDrop(reason: String) {
    logEvent("drop: \(reason)")
    apply(link.handle(.dropped(reconnectAllowed: keepGlassesAlive)))
  }

  private func apply(_ action: GlassesLinkAction) {
    switch action {
    case .none:
      break
    case .stop:
      markStopped()
    case .scheduleRetry(let delay):
      // Keep streamingStatus off .stopped: StreamView closing would end Scout.
      tearDownGlassesLink()
      currentVideoFrame = nil
      streamingStatus = .waiting
      isReconnectingGlasses = true
      attemptWatchdog?.cancel()
      retryTask?.cancel()
      retryTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .seconds(delay))
        guard let self, !Task.isCancelled else { return }
        self.apply(self.link.handle(.retryFired(reconnectAllowed: self.keepGlassesAlive)))
      }
    case .retryNow:
      logEvent("reconnect attempt")
      startAttemptWatchdog()
      connectGlasses()
    }
  }

  /// A reconnect attempt that has not produced frames in time counts as a drop.
  private func startAttemptWatchdog() {
    attemptWatchdog?.cancel()
    attemptWatchdog = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(GlassesLinkSupervisor.attemptTimeout))
      guard let self, !Task.isCancelled, self.link.phase == .connecting else { return }
      self.handleGlassesDrop(reason: "reconnect attempt timed out")
    }
  }

  /// Ends glasses streaming and returns the UI to the start screen.
  private func markStopped() {
    _ = link.handle(.stopped)
    retryTask?.cancel()
    retryTask = nil
    attemptWatchdog?.cancel()
    attemptWatchdog = nil
    isReconnectingGlasses = false
    wantsStream = false
    tearDownGlassesLink()
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
  }

  /// Stops and forgets the current camera and session. Bumping the generations
  /// makes any of their late events ignored.
  private func tearDownGlassesLink() {
    camera?.stop()
    deviceSession?.stop()
    camera = nil
    deviceSession = nil
    cameraGeneration &+= 1
    sessionGeneration &+= 1
    sessionStateListenerToken = nil
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func noteDeliveredFrame(_ sampleBuffer: CMSampleBuffer) {
    let now = Date()
    if !loggedFirstFrame {
      loggedFirstFrame = true
      deliveredFrames = 0
      frameWindowStart = now
      if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        logEvent("first frame \(size.width)x\(size.height) (requested \(resolutionLabel))")
      }
    }
    deliveredFrames += 1
    let elapsed = now.timeIntervalSince(frameWindowStart)
    if elapsed >= 10 {
      logEvent(String(format: "%.1f fps delivered", Double(deliveredFrames) / elapsed))
      deliveredFrames = 0
      frameWindowStart = now
    }
  }

  private func logEvent(_ text: String) {
    GlassesEventLogStore.shared.record(text)
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  func stopSession() async {
    if streamingMode == .iPhone {
      stopIPhoneSession()
      return
    }
    logEvent("user stopped streaming")
    markStopped()
  }

  // MARK: - iPhone Camera Mode

  func handleStartIPhone() async {
    let granted = await IPhoneCameraManager.requestPermission()
    if granted {
      startIPhoneSession()
    } else {
      showError("Camera permission denied. Please grant access in Settings.")
    }
  }

  private func startIPhoneSession() {
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onFrameCaptured = { [weak self] image in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.currentVideoFrame = image
        if !self.hasReceivedFirstFrame {
          self.hasReceivedFirstFrame = true
        }
        self.geminiSessionVM?.sendVideoFrameIfThrottled(image: image)
        self.webrtcSessionVM?.pushVideoFrame(image)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    streamingMode = .glasses
    NSLog("[Stream] iPhone camera mode stopped")
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func capturePhoto() {
    _ = camera?.stream.capturePhoto(format: .jpeg)
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }
}
