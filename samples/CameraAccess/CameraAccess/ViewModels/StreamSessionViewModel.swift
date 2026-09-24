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

import AVFoundation
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
  @Published var selectedResolution: StreamingResolution = .high
  @Published private(set) var isReconnectingGlasses = false
  /// What the glasses screen should say; recomputed twice a second while
  /// glasses streaming is on (see GlassesStatusRule).
  @Published private(set) var glassesStatus: GlassesStatus = .connecting

  var isStreaming: Bool {
    streamingStatus != .stopped
  }

  /// Reconnect only while a Scout session is running, or its report is still
  /// waiting to be sent (End lives on the streaming screen), or while a Track
  /// Walk runs (a fold's stream stop must reconnect so unfolding resumes; a
  /// bare stop finishes the walk and the link then winds down).
  private var keepGlassesAlive: Bool {
    if trackWalk.isActive { return true }
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

  /// Non-nil in iPhone mode: the view draws an AVCaptureVideoPreviewLayer off
  /// the live session instead of showing converted frames.
  var iPhoneCaptureSession: AVCaptureSession? { iPhoneCameraManager?.session }

  /// Shown while pinching, and reset when the camera stops.
  @Published var iPhoneZoom: CGFloat = 1
  /// Zoom when the current pinch began; a magnify gesture reports scale
  /// relative to its own start, not to the last committed value.
  private var zoomAtGestureStart: CGFloat = 1

  func beginIPhoneZoomGesture() {
    zoomAtGestureStart = iPhoneZoom
  }

  func updateIPhoneZoom(scale: CGFloat) {
    guard let camera = iPhoneCameraManager else { return }
    let target = min(max(zoomAtGestureStart * scale, 1), camera.maxAvailableZoom)
    iPhoneZoom = target
    camera.setZoom(target)
  }

  // Every source publishes each frame here once; the preview, Gemini and
  // WebRTC consumers subscribe and apply their own rates.
  private let frameHub = FrameHub()
  let trackWalk = TrackWalkController()
  private let imageRenderer = PixelBufferImageRenderer()
  private var previewThrottle = FrameThrottle(minimumInterval: 1.0 / 8)
  private var geminiThrottle = FrameThrottle(minimumInterval: GeminiConfig.videoFrameInterval)
  // Compressed glasses samples (HEVC, or raw once backgrounded) are decoded
  // here, off the main thread. VideoDecoder is used only on this queue.
  private let videoDecoder = VideoDecoder()
  private let decodeQueue = DispatchQueue(label: "glasses-decode", qos: .userInitiated)
  // Glasses status inputs: when the user tapped Start, when the last frame
  // arrived, and whether the glasses reported their hinges closed since then.
  private var glassesStartedAt: TimeInterval = 0
  private var lastGlassesFrameAt: TimeInterval?
  private var glassesReportedFolded = false
  private var statusTicker: Task<Void, Never>?
  // Folding the glasses during a Race ends it after 10 s unless they are
  // unfolded first (spec §B2). A bare stream stop never ends a Race.
  private var foldEndTask: Task<Void, Never>?
  private static let foldEndDelay: Duration = .seconds(10)
  // failureCount when the current glasses stream began; decode failures log relative to it.
  private var decodeFailureBaseline = 0
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
    subscribeFrameConsumers()
  }

  private func setupVideoDecoder() {
    // Runs on the decode queue; hop to the main actor to publish.
    videoDecoder.setFrameCallback { [weak self] decodedFrame in
      let frame = VideoFrameSample(
        pixelBuffer: decodedFrame.pixelBuffer,
        timestamp: decodedFrame.presentationTimeStamp)
      Task { @MainActor [weak self] in
        self?.frameHub.publish(frame)
      }
    }
  }

  func subscribeFrames(_ subscriber: @escaping (VideoFrameSample) -> Void) -> UUID {
    frameHub.subscribe(subscriber)
  }

  func unsubscribeFrames(_ id: UUID) {
    frameHub.unsubscribe(id)
  }

  private func subscribeFrameConsumers() {
    frameHub.subscribe { [weak self] frame in self?.showPreview(frame) }
    frameHub.subscribe { [weak self] frame in self?.sendToGemini(frame) }
    frameHub.subscribe { [weak self] frame in
      self?.webrtcSessionVM?.pushVideoFrame(frame.pixelBuffer)
    }
  }

  /// At most 8 preview images a second, and none while backgrounded.
  private func showPreview(_ frame: VideoFrameSample) {
    guard streamingMode == .glasses || webrtcSessionVM?.isActive == true,
          UIApplication.shared.applicationState != .background,
          previewThrottle.shouldPass(at: ProcessInfo.processInfo.systemUptime)
    else { return }
    imageRenderer.render(frame.pixelBuffer) { [weak self] image in
      // A render that finishes after the stream stopped or dropped must not bring an old frame back.
      guard let self, self.streamingStatus == .streaming else { return }
      self.currentVideoFrame = image
      if !self.hasReceivedFirstFrame {
        self.hasReceivedFirstFrame = true
      }
    }
  }

  /// One frame a second to Gemini while Scout runs, locked screen included.
  private func sendToGemini(_ frame: VideoFrameSample) {
    guard let gemini = geminiSessionVM, gemini.isGeminiActive,
          gemini.connectionState == .ready,
          SettingsManager.shared.videoStreamingEnabled,
          geminiThrottle.shouldPass(at: ProcessInfo.processInfo.systemUptime)
    else { return }
    imageRenderer.render(frame.pixelBuffer) { [weak gemini] image in
      gemini?.sendVideoFrame(image: image)
    }
  }

  /// Raw samples carry a pixel buffer and publish directly. Compressed ones
  /// (HEVC, or raw once the app is backgrounded) go to the decoder, whose
  /// callback publishes.
  private func ingestGlassesSample(_ sampleBuffer: CMSampleBuffer) {
    if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
      frameHub.publish(VideoFrameSample(
        pixelBuffer: pixelBuffer,
        timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
      return
    }
    let decoder = videoDecoder
    let baseline = decodeFailureBaseline
    decodeQueue.async { [weak self] in
      do {
        try decoder.decode(sampleBuffer)
      } catch {
        let failures = decoder.failureCount - baseline
        if failures <= 3 || failures % 120 == 0 {
          NSLog("[Stream] decode failed (#%d): %@", failures, String(describing: error))
        }
        if failures == 1 {
          let text = "decode failed: \(String(describing: error))"
          Task { @MainActor [weak self] in
            self?.logEvent(text)
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

  // 15 fps: Meta's docs say per-frame compression adapts to the Bluetooth
  // budget, so asking for fewer frames leaves more bits per frame. That suits a
  // vision model reading stills, and halves the decode work while locked.
  private let requestedFrameRate: UInt = 15

  private func streamConfig() -> StreamConfiguration {
    // HEVC rather than raw: raw 720x1280 is ~1.4 MB a frame, far more than the
    // glasses link carries, so the SDK laddered down to a lower tier. HEVC is
    // 10-30x smaller, so the top tier fits. Samples arrive compressed and are
    // decoded in ingestGlassesSample.
    StreamConfiguration(
      videoCodec: VideoCodec.hvc1,
      resolution: selectedResolution,
      frameRate: requestedFrameRate)
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
    previewThrottle.reset()
    geminiThrottle.reset()
    glassesStartedAt = ProcessInfo.processInfo.systemUptime
    lastGlassesFrameAt = nil
    glassesReportedFolded = false
    glassesStatus = .connecting
    startStatusTicker()
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
    let decoder = videoDecoder
    decodeQueue.async { [weak self] in
      let baseline = decoder.failureCount
      Task { @MainActor [weak self] in self?.decodeFailureBaseline = baseline }
    }
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
        // Only while Scout audio is up and the owner hasn't asked for the phone speaker.
        if self?.geminiSessionVM?.isGeminiActive == true,
           !SettingsManager.shared.speakerOutputEnabled,
           GlassesAudioRoute.selectGlassesMicIfNeeded() {
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
      let sampleBuffer = videoFrame.sampleBuffer
      Task { @MainActor [weak self] in
        guard let self, generation == self.cameraGeneration else { return }
        self.noteDeliveredFrame(sampleBuffer)
        self.ingestGlassesSample(sampleBuffer)
      }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor [weak self] in
        guard let self, generation == self.cameraGeneration else { return }
        self.logEvent("stream error: \(String(describing: error))")
        if case .hingesClosed = error {
          self.glassesReportedFolded = true
          self.refreshGlassesStatus()
          self.startFoldToEndIfRacing()
          self.trackWalk.glassesFolded()
        }
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
    if trackWalk.isActive && !glassesReportedFolded {
      trackWalk.glassesStreamStopped()
    }
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
    if trackWalk.isActive { Task { await trackWalk.finish(reason: .leftScreen) } }
    _ = link.handle(.stopped)
    retryTask?.cancel()
    retryTask = nil
    attemptWatchdog?.cancel()
    attemptWatchdog = nil
    statusTicker?.cancel()
    statusTicker = nil
    foldEndTask?.cancel()
    foldEndTask = nil
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

  /// Recomputes the glasses status twice a second while glasses streaming is on.
  private func startStatusTicker() {
    statusTicker?.cancel()
    statusTicker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard let self else { return }
        self.refreshGlassesStatus()
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

  private func startFoldToEndIfRacing() {
    guard foldEndTask == nil, let gemini = geminiSessionVM, gemini.isGeminiActive else { return }
    logEvent("fold: ending Race in 10 s unless unfolded")
    // The Race is still live: stay on the current route (forcing the speaker moves the mic and resets the audio engine).
    SpokenCues.shared.speak("Ending Race in 10 seconds, unfold to cancel", onPhoneSpeaker: false)
    foldEndTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: Self.foldEndDelay)
      guard let self, !Task.isCancelled else { return }
      self.foldEndTask = nil
      guard self.glassesReportedFolded, let gemini = self.geminiSessionVM, gemini.isGeminiActive else { return }
      self.logEvent("fold: ending Race")
      switch await gemini.endScout() {
      case .sent:
        SpokenCues.shared.speak("Report sent to Setup_IQ", onPhoneSpeaker: true)
      case .queued:
        SpokenCues.shared.speak("Report saved. It will send when you have signal.", onPhoneSpeaker: true)
      case .testMode:
        SpokenCues.shared.speak("Test mode. Report not sent.", onPhoneSpeaker: true)
      case .nothingToSend:
        SpokenCues.shared.speak("Race ended", onPhoneSpeaker: true)
      }
    }
  }

  private func refreshGlassesStatus() {
    let status = GlassesStatusRule.status(
      now: ProcessInfo.processInfo.systemUptime,
      startedAt: glassesStartedAt,
      lastFrameAt: lastGlassesFrameAt,
      hingesClosed: glassesReportedFolded)
    if status != glassesStatus {
      logEvent("glasses status: \(status)")
      glassesStatus = status
    }
  }

  private func noteDeliveredFrame(_ sampleBuffer: CMSampleBuffer) {
    if glassesReportedFolded {
      trackWalk.glassesUnfolded()
    }
    if glassesReportedFolded, foldEndTask != nil {
      foldEndTask?.cancel()
      foldEndTask = nil
      logEvent("fold: unfolded, Race continues")
      SpokenCues.shared.speak("Race continues", onPhoneSpeaker: false)
    }
    lastGlassesFrameAt = ProcessInfo.processInfo.systemUptime
    glassesReportedFolded = false
    let now = Date()
    if !loggedFirstFrame {
      loggedFirstFrame = true
      deliveredFrames = 0
      frameWindowStart = now
      if let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
        let size = CMVideoFormatDescriptionGetDimensions(format)
        logEvent("first frame \(size.width)x\(size.height) (requested \(resolutionLabel) @ \(requestedFrameRate) fps, HEVC)")
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
    previewThrottle.reset()
    geminiThrottle.reset()
    streamingMode = .iPhone
    let camera = IPhoneCameraManager()
    camera.onPixelBuffer = { [weak self] pixelBuffer, timestamp in
      let frame = VideoFrameSample(pixelBuffer: pixelBuffer, timestamp: timestamp)
      Task { @MainActor [weak self] in
        self?.frameHub.publish(frame)
      }
    }
    camera.start()
    iPhoneCameraManager = camera
    streamingStatus = .streaming
    NSLog("[Stream] iPhone camera mode started")
  }

  private func stopIPhoneSession() {
    if trackWalk.isActive { Task { await trackWalk.finish(reason: .leftScreen) } }
    iPhoneCameraManager?.stop()
    iPhoneCameraManager = nil
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    streamingStatus = .stopped
    iPhoneZoom = 1
    zoomAtGestureStart = 1
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
