import Foundation
import SwiftUI
import AVFoundation

/// How an End went, so callers (the fold-to-end countdown) can say so.
enum EndScoutResult: Equatable {
  case sent
  case queued
  case nothingToSend
  case testMode
}

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
  /// Race always reports from the driver's stand (spec §B2).
  static let raceContext = "Driver Stand"
  private(set) var spectreTrackName: String = ""
  private(set) var scoutVehicleModel: String = ""

  private let geminiService = GeminiLiveService()
  private let audioManager = AudioManager()
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
  // Race silence rule (30 min warn, 45 min end); checked every 30 s while active.
  // Activity is the racer's own speech (input transcription) only — the phone's
  // spoken prompts must never count as the racer talking.
  private var idleGuard = IdleGuard(now: 0)
  private var idleTicker: Task<Void, Never>?

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
      sessionInfo = try await resolveSession()
    } catch {
      isFetchingSession = false
      errorMessage = error.localizedDescription
      return
    }
    isFetchingSession = false

    spectreSessionId = sessionInfo.sessionId
    spectreTrackName = sessionInfo.track
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
    idleGuard = IdleGuard(now: ProcessInfo.processInfo.systemUptime)
    startIdleTicker()

    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        // The phone's own prompts must not be heard as the racer.
        if SpokenCues.shared.isSpeaking { return }
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
        self.idleGuard.noteActivity(at: ProcessInfo.processInfo.systemUptime)
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
    idleTicker?.cancel()
    idleTicker = nil
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

  /// Ends the Race and hands the transcript to the Outbox, which saves it
  /// before sending and keeps retrying if the signal is gone.
  @discardableResult
  func endScout() async -> EndScoutResult {
    flushPendingTurn()
    guard !scoutReportSent, !spectreSessionId.isEmpty, !scoutHistory.isEmpty else {
      stopSession()
      return .nothingToSend
    }

    if SettingsManager.shared.scoutTestMode {
      stopSession()
      let turns = scoutHistory.count
      let minutes = scoutStartTime.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0
      NSLog("[ScoutVM] Test mode: report not sent (%d turns, %d min)", turns, minutes)
      scoutReportSent = true
      errorMessage = "Test mode — report not sent (\(turns) turns, \(minutes) min)"
      return .testMode
    }

    isSendingScoutReport = true
    stopSession()
    let capture = Capture(
      mode: .race,
      sessionId: spectreSessionId,
      trackName: spectreTrackName,
      transcript: scoutHistory.map { TranscriptLine(role: $0.role, text: $0.text) },
      scoutContext: Self.raceContext,
      vehicleModel: scoutVehicleModel.isEmpty ? "Unspecified" : scoutVehicleModel,
      durationMin: scoutStartTime.map { Int(Date().timeIntervalSince($0) / 60) } ?? 0)
    // Saved to disk inside submit before the first attempt, so the transcript
    // is safe from here on even if this send fails.
    scoutReportSent = true
    let state = await ScoutOutbox.shared.submit(capture)
    isSendingScoutReport = false
    if state == .done {
      return .sent
    }
    errorMessage = "No signal — the report is saved and will send automatically. See Settings → Scout reports."
    return .queued
  }

  /// Sends one frame to Gemini. The caller (StreamSessionViewModel's FrameHub
  /// consumer) already limits this to GeminiConfig.videoFrameInterval.
  func sendVideoFrame(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    geminiService.sendVideoFrame(image: image)
  }

  // MARK: - Private

  private func startIdleTicker() {
    idleTicker?.cancel()
    idleTicker = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(30))
        guard let self, !Task.isCancelled, self.isGeminiActive else { return }
        switch self.idleGuard.check(at: ProcessInfo.processInfo.systemUptime) {
        case .none:
          break
        case .warn:
          NSLog("[ScoutVM] Idle 30 min: reminding")
          SpokenCues.shared.speak("Scout still running")
        case .end:
          NSLog("[ScoutVM] Idle 45 min: ending the Race")
          let result = await self.endScout()
          let message: String
          switch result {
          case .sent: message = "Race ended after 45 quiet minutes. Report sent to Setup_IQ."
          case .queued: message = "Race ended after 45 quiet minutes. Report saved."
          case .nothingToSend: message = "Race ended after 45 quiet minutes."
          case .testMode: message = "Race ended after 45 quiet minutes. Test mode, report not sent."
          }
          SpokenCues.shared.speak(message, onPhoneSpeaker: true)
          return
        }
      }
    }
  }

  /// Resolve the active Spectre session, or a synthetic one when Scout test mode is on
  /// (device-testing Gemini Live with no SPECTRE session running).
  private func resolveSession() async throws -> ActiveSessionInfo {
    if SettingsManager.shared.scoutTestMode {
      return ActiveSessionInfo(sessionId: "test-mode", track: "Test Track", vehicles: ["Test Buggy", "Test Truggy"])
    }
    return try await scoutBridge.fetchActiveSession()
  }

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
      // Gemini is gone for good: save the transcript to the Outbox now rather
      // than leaving it in memory, where a pocketed phone could lose it.
      let result = await self.endScout()
      let message: String
      switch result {
      case .sent: message = "Scout connection lost. Report sent to Setup_IQ."
      case .queued: message = "Scout connection lost. Report saved."
      case .nothingToSend: message = "Scout connection lost. Race ended."
      case .testMode: message = "Scout connection lost. Test mode, report not sent."
      }
      SpokenCues.shared.speak(message, onPhoneSpeaker: true)
      if self.errorMessage == nil {
        self.errorMessage = "Connection lost (\(reason)). The report was handed to the Outbox — see Settings → Scout reports."
      }
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

  /// Pick out which vehicle the racer named, from their own words.
  private func extractOpeningSequenceAnswers(from racerText: String) {
    let lower = racerText.lowercased()

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
