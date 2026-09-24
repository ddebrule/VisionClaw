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
  private var scoutHistory: [ScoutTranscriptEntry] = []
  private var scoutStartTime: Date?
  private var pendingUserText: String = ""
  private var pendingAIText: String = ""
  private var sessionVehicles: [String] = []  // vehicle model names from active session

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }
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

    let dynamicInstruction = GeminiConfig.defaultSystemInstruction + """

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

    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
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
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
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
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    pendingUserText = ""
    pendingAIText = ""
  }

  /// Send accumulated field report to Spectre Setup_IQ and end the session.
  func endScout() async {
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
