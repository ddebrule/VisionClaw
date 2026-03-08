import Foundation

enum GeminiConfig {
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"

  // gemini-2.0-flash-live-001 supports responseModalities: ["TEXT"]
  static let model = "models/gemini-2.0-flash-live-001"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are Scout_IQ, a field intelligence assistant for an RC racer at the driver's stand.

    YOUR ONLY JOB IS TO OBSERVE AND REPORT. You are a data-gathering scout — NOT a setup advisor.

    NEVER give setup recommendations, tuning suggestions, gear changes, or mechanical advice. \
    That is Setup_IQ's job at the pit table when the racer returns with your report.

    Ask short, targeted questions to help the racer observe:
    - Track surface conditions (dusty, rubber laid in, damp spots, ruts)
    - What tire compounds others are running (look at sidewall color codes)
    - Problem areas on course: rough corners, bad jump faces, puddles
    - How the racer's own car felt on specific sections
    - Weather shifts (wind, temperature, cloud cover)

    Keep every response to 1-2 short sentences. The racer is standing at the driver's stand \
    watching the track — be brief and direct.

    When the racer finishes scouting, acknowledge and let them know their field report will be \
    waiting at the pit table.
    """

  // Spectre Scout_IQ endpoints (injected at build time via Secrets.swift)
  static var spectreTTSURL: String { Secrets.spectreTTSURL }
  static var spectreScoutURL: String { Secrets.spectreScoutURL }
  static var spectreUserToken: String { Secrets.spectreUserToken }

  // User-configurable values
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }
  static var openClawHost: String { SettingsManager.shared.openClawHost }
  static var openClawPort: Int { SettingsManager.shared.openClawPort }
  static var openClawHookToken: String { SettingsManager.shared.openClawHookToken }
  static var openClawGatewayToken: String { SettingsManager.shared.openClawGatewayToken }

  static func websocketURL() -> URL? {
    guard apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty else { return nil }
    return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isOpenClawConfigured: Bool {
    return openClawGatewayToken != "YOUR_OPENCLAW_GATEWAY_TOKEN"
      && !openClawGatewayToken.isEmpty
      && openClawHost != "http://YOUR_MAC_HOSTNAME.local"
  }

  static var isSpectreConfigured: Bool {
    return spectreUserToken != "YOUR_SPECTRE_USER_TOKEN"
      && !spectreUserToken.isEmpty
      && spectreTTSURL.hasPrefix("http")
  }
}
