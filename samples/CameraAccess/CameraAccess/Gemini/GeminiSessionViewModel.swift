import Foundation
import SwiftUI
import AVFoundation

// MARK: - GeminiSessionViewModel

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var isSendingScoutReport: Bool = false
  @Published var scoutReportSent: Bool = false
  @Published var isFetchingSession: Bool = false
  @Published var isReconnecting: Bool = false

  /// A transcript exists that has not reached Setup_IQ. End stays available for it
  /// even after the live connection is gone.
  var hasUnsentReport: Bool { !scoutHistory.isEmpty && !scoutReportSent }

  // Resolved at session start
  private(set) var spectreSessionId: String = ""
  private(set) var scoutContext: String = ""
  private(set) var scoutVehicleModel: String = ""

  private let geminiService = GeminiLiveService()
  private let audioManager = AudioManager()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?

  // Scout_IQ transcript accumulation
  private let scoutBridge = SpectreScoutBridge()
  @Published private var scoutHistory: [ScoutTranscriptEntry] = []
  private var scoutStartTime: Date?
  private var pendingUserText: String = ""
  private var pendingAIText: String = ""
  private var sessionVehicles: [String] = []  // vehicle model names from active session
  private var dynamicInstruction: String = ""
  private var reconnectTask: Task<Void, Never>?
  // goAway arrived mid-reply; reconnect once the turn completes.
  private var reconnectWhenIdle = false

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }
    guard !hasUnsentReport else {
      errorMessage = "Send or discard the last Scout report first (tap End)."
      return
    }
    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured."
      return
    }

    // 1. Fetch active Spectre session + vehicle list
    isFetchingSession = true
    let sessionInfo: ActiveSessionInfo
    do {
      sessionInfo = try await scoutBridge.fetchActiveSession()
    } catch {
      isFetchingSession = false
      errorMessage = error.localizedDescription
      return
    }
    isFetchingSession = false

    spectreSessionId = sessionInfo.sessionId
    scoutContext = ""
    scoutVehicleModel = ""
    sessionVehicles = sessionInfo.vehicles

    // 2. Build dynamic system instruction with vehicle list injected
    let vehicleList = sessionInfo.vehicles.isEmpty
      ? "No vehicles found in garage."
      : sessionInfo.vehicles.map { "- \($0)" }.joined(separator: "\n")

    dynamicInstruction = GeminiConfig.defaultSystemInstruction + """

    ─── VEHICLES IN RACER'S GARAGE ───
    \(vehicleList)
    ──────────────────────────────────
    Track today: \(sessionInfo.track)
    """

    isGeminiActive = true
    scoutHistory = []
    scoutStartTime = Date()
    pendingUserText = ""
    pendingAIText = ""
    scoutReportSent = false
    reconnectWhenIdle = false
    geminiService.resetResumption()

    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        // isModelSpeaking covers the gap before the first buffer is scheduled;
        // isSpeakerActive covers the tail that plays after generation ends.
        if speakerOnPhone && (self.geminiService.isModelSpeaking || self.audioManager.isSpeakerActive) { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    geminiService.onAudioReceived = { [weak self] data in
      self?.audioManager.playAudio(data: data)
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
    }

    // AI speech transcription — accumulate for scout report and extract context/vehicle
    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
        self.pendingAIText += text
      }
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        if !self.pendingUserText.isEmpty {
          self.scoutHistory.append(ScoutTranscriptEntry(role: "user", text: self.pendingUserText))
          // Extract scout context and vehicle model from racer responses
          // These are set by parsing the opening sequence conversation
          self.extractOpeningSequenceAnswers(from: self.pendingUserText)
        }
        if !self.pendingAIText.isEmpty {
          self.scoutHistory.append(ScoutTranscriptEntry(role: "assistant", text: self.pendingAIText))
        }
        self.pendingUserText = ""
        self.pendingAIText = ""
        self.userTranscript = ""
        self.aiTranscript = ""
        if self.reconnectWhenIdle {
          self.reconnectWhenIdle = false
          // The reply is complete but its tail may still be playing; let it finish.
          self.reconnect(reason: "server connection limit", cutPlayback: false)
        }
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.pendingUserText += text
        self.aiTranscript = ""
      }
    }

    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        self.reconnect(reason: reason ?? "Unknown error")
      }
    }

    // The socket stays usable after goAway, so let an in-flight reply finish and
    // reconnect at the next turn boundary. The server's own close still arrives via
    // onDisconnected as a backstop.
    geminiService.onGoAway = { [weak self] _ in
      guard let self else { return }
      Task { @MainActor in
        let idle = !self.geminiService.isModelSpeaking && !self.audioManager.isSpeakerActive
          && self.pendingUserText.isEmpty && self.pendingAIText.isEmpty
        if idle {
          self.reconnect(reason: "server connection limit")
        } else {
          self.reconnectWhenIdle = true
        }
      }
    }

    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
      }
    }

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    // 3. Connect with dynamic system instruction (includes vehicle list)
    let setupOk = await geminiService.connect(systemInstruction: dynamicInstruction)
    if !setupOk {
      let msg: String
      if case .error(let err) = geminiService.connectionState { msg = err }
      else { msg = "Failed to connect to Gemini" }
      errorMessage = msg
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }
  }

  func stopSession() {
    reconnectTask?.cancel()
    reconnectTask = nil
    isReconnecting = false
    reconnectWhenIdle = false
    flushPendingTurn()
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
  }

  /// Throw away an unsent transcript (the racer chose Discard).
  func discardReport() {
    scoutHistory = []
    scoutReportSent = false
  }

  /// Send accumulated field report to Spectre Setup_IQ and end the session.
  func endScout() async {
    flushPendingTurn()
    guard !spectreSessionId.isEmpty, !scoutHistory.isEmpty else {
      stopSession()
      return
    }
    isSendingScoutReport = true
    stopSession()
    let duration = scoutStartTime.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
    let context = scoutContext.isEmpty ? "Unspecified" : scoutContext
    let vehicle = scoutVehicleModel.isEmpty ? "Unspecified" : scoutVehicleModel
    do {
      try await scoutBridge.sendReport(
        sessionId: spectreSessionId,
        transcript: scoutHistory,
        durationMin: duration,
        scoutContext: context,
        vehicleModel: vehicle
      )
      scoutReportSent = true
    } catch {
      NSLog("[ScoutVM] Failed to send report: %@", error.localizedDescription)
      errorMessage = "Scout report failed to send. Check your connection."
    }
    isSendingScoutReport = false
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  // MARK: - Private

  /// Keep a Race going across Google's ~10-minute connection limit and signal drops.
  /// Audio capture keeps running; GeminiLiveService drops audio until it is ready again.
  /// `cutPlayback: false` lets an already-complete reply finish playing (goAway at a turn boundary).
  private func reconnect(reason: String, cutPlayback: Bool = true) {
    // Any reconnect replaces the connection a pending goAway referred to.
    reconnectWhenIdle = false
    guard isGeminiActive, reconnectTask == nil else { return }
    NSLog("[ScoutVM] Reconnecting Gemini: %@", reason)
    isReconnecting = true
    if cutPlayback { audioManager.stopPlayback() }
    flushPendingTurn()
    reconnectTask = Task { [weak self] in
      guard let self else { return }
      var failures = 0
      // Only attempts the server refused during setup count against the handle;
      // a network drop says nothing about whether the handle is stale.
      var refusals = 0
      while let delay = ReconnectPolicy.delay(afterConsecutiveFailures: failures) {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        guard !Task.isCancelled, self.isGeminiActive else { return }
        if refusals == ReconnectPolicy.dropHandleAfterFailures {
          NSLog("[ScoutVM] Resumption handle refused twice by the server; starting a fresh Gemini session")
          self.geminiService.resetResumption()
          refusals += 1  // reset only once per reconnect
        }
        self.geminiService.disconnect()
        if await self.geminiService.connect(systemInstruction: self.dynamicInstruction) {
          NSLog("[ScoutVM] Gemini reconnected (resumed: %@)",
                self.geminiService.resumptionHandle == nil ? "no" : "yes")
          self.isReconnecting = false
          self.reconnectTask = nil
          return
        }
        if self.geminiService.lastAttemptReachedServer { refusals += 1 }
        failures += 1
      }
      self.isReconnecting = false
      self.reconnectTask = nil
      guard self.isGeminiActive else { return }
      self.stopSession()
      self.errorMessage = "Connection lost (\(reason)). Tap End to send what was captured."
    }
  }

  /// Move any half-finished turn into the transcript so a drop or stop never loses it.
  private func flushPendingTurn() {
    if !pendingUserText.isEmpty {
      scoutHistory.append(ScoutTranscriptEntry(role: "user", text: pendingUserText))
      extractOpeningSequenceAnswers(from: pendingUserText)
    }
    if !pendingAIText.isEmpty {
      scoutHistory.append(ScoutTranscriptEntry(role: "assistant", text: pendingAIText))
    }
    pendingUserText = ""
    pendingAIText = ""
  }

  /// Parse racer responses from the opening sequence to extract context and vehicle model.
  /// Scout_IQ confirms answers with "Locked in. [vehicle] — [context]." — we watch for that pattern
  /// in AI output. As a fallback we also watch racer input for known keywords.
  private func extractOpeningSequenceAnswers(from racerText: String) {
    let lower = racerText.lowercased()

    if scoutContext.isEmpty {
      if lower.contains("track walk") || lower.contains("walk") { scoutContext = "Track Walk" }
      else if lower.contains("qualifying") || lower.contains("qual") { scoutContext = "Qualifying" }
      else if lower.contains("practice") { scoutContext = "Practice" }
      else if lower.contains("between") || lower.contains("post") { scoutContext = "Between Rounds" }
    }

    if scoutVehicleModel.isEmpty {
      for vehicle in sessionVehicles {
        if lower.contains(vehicle.lowercased()) {
          scoutVehicleModel = vehicle
          break
        }
        // Also match individual words from the model name (e.g. "buggy" matches "Nitro Buggy")
        let words = vehicle.lowercased().split(separator: " ")
        if words.count > 1 && words.contains(where: { lower.contains($0) }) {
          scoutVehicleModel = vehicle
          break
        }
      }
    }
  }
}
