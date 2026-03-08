import Foundation
import SwiftUI
import AVFoundation

// MARK: - Scout data types

struct ScoutTranscriptEntry {
  let role: String  // "user" or "assistant"
  let text: String
}

// MARK: - SpectreScoutBridge

@MainActor
class SpectreScoutBridge {
  private let session: URLSession

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 60
    self.session = URLSession(configuration: config)
  }

  func sendReport(sessionId: String, transcript: [ScoutTranscriptEntry], durationMin: Int) async throws {
    guard let url = URL(string: GeminiConfig.spectreScoutURL) else { throw URLError(.badURL) }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(GeminiConfig.spectreUserToken, forHTTPHeaderField: "X-Scout-Token")

    let transcriptArray = transcript.map { ["role": $0.role, "text": $0.text] }
    let body: [String: Any] = [
      "session_id": sessionId,
      "transcript": transcriptArray,
      "duration_min": durationMin,
    ]

    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    NSLog("[SpectreScout] Report sent. %d turns, %d min", transcript.count, durationMin)
  }
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
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  @Published var isSendingScoutReport: Bool = false
  @Published var scoutReportSent: Bool = false

  /// Set this to the Spectre live session ID before starting Scout_IQ
  var spectreSessionId: String = ""

  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?

  // Scout_IQ transcript accumulation
  private let scoutBridge = SpectreScoutBridge()
  private var scoutHistory: [ScoutTranscriptEntry] = []
  private var scoutStartTime: Date?
  private var pendingUserText: String = ""
  private var pendingAIText: String = ""

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }
    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured."
      return
    }

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

    // AI speech transcription — accumulate for scout report
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

    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    let setupOk = await geminiService.connect()
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
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
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
    do {
      try await scoutBridge.sendReport(
        sessionId: spectreSessionId,
        transcript: scoutHistory,
        durationMin: duration
      )
      scoutReportSent = true
    } catch {
      NSLog("[ScoutVM] Failed to send report: %@", error.localizedDescription)
      errorMessage = "Scout report failed to send. Check your connection."
    }
    isSendingScoutReport = false
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }
}
