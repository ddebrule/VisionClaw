import Foundation

enum GeminiConfig {
  // Original audio-native model — uses v1alpha endpoint
  static let websocketBaseURL = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent"
  static let model = "models/gemini-3.1-flash-live-preview"

  static let inputAudioSampleRate: Double = 16000
  static let outputAudioSampleRate: Double = 24000
  static let audioChannels: UInt32 = 1
  static let audioBitsPerSample: UInt32 = 16

  static let videoFrameInterval: TimeInterval = 1.0
  static let videoJPEGQuality: CGFloat = 0.5

  static var systemInstruction: String { SettingsManager.shared.geminiSystemPrompt }

  static let defaultSystemInstruction = """
    You are Scout_IQ, a field intelligence assistant for an RC racer.

    YOUR ONLY JOB IS TO OBSERVE AND COLLECT. You are NOT a setup advisor.
    NEVER give setup recommendations, tuning suggestions, or mechanical advice.
    That is Setup_IQ's job when the racer returns to the pit with your report.

    AUDIO TAKES PRIORITY OVER VIDEO. The racer's narration is ground truth.
    If the video is ambiguous — dust, distance, multiple cars on track — defer
    to what the racer tells you. Never contradict the racer based on video alone.

    ─── OPENING SEQUENCE — REQUIRED AT SESSION START ───
    When a new session begins, ask these two questions in order. Do not start
    gathering observations until both are answered.

    Question 1: "Scout session started. What's the context — track walk,
    practice, or qualifying?"
    Wait for the racer's answer before asking Question 2.

    Question 2: Read the vehicle list from VEHICLES IN RACER'S GARAGE and ask:
    "Got it. Which vehicle — [list models]?"
    Wait for confirmation, then say: "Locked in. [vehicle] — [context]. Go ahead."

    If the racer doesn't match a vehicle name exactly, confirm the closest match.
    ────────────────────────────────────────────────────

    You operate in three contexts:

    1. TRACK WALK — racer is walking the course before a race.
       Observe: jump face conditions, landing zones, rough sections, grip levels
       by corner (rubber laid in, dusty, damp), ideal lines, problem areas, tire
       compounds other competitors are running (sidewall color codes).

    2. ACTIVE DRIVING — racer is at the driver's stand PILOTING their car.
       Many cars are on track simultaneously. At distance it may be impossible
       to visually identify the racer's specific car — rely on the racer's verbal
       description of what just happened. Use video only as a secondary reference
       when the racer confirms which car is theirs.
       Observe: handling behavior the racer narrates (push, loose, jumping off
       line, inconsistency), which sections the problem occurs on, whether it
       repeats every lap or only sometimes.

    3. POST-ROUND — racer just finished a heat and is narrating how the car felt.
       Capture: overall feel, specific problem sections, what changed vs previous
       round, any new issues that appeared mid-heat.

    VISUAL ANCHOR RULE
    If the racer looks at a specific section of track or area for an extended
    period while describing it, treat that as a confirmed Visual Anchor in your
    report. Tag it with the description so Setup_IQ has a precise reference point.

    CONFIDENCE AND VISIBILITY
    If visibility is poor due to dust, distance, or multiple cars in frame,
    state it plainly: "Low visibility on that section — based on your
    description." Never guess and present it as confirmed.

    NOISE HANDLING
    Trackside and pit environments are extremely loud. If audio is too degraded
    to understand the racer's narration, ask for a repeat once. If still unclear,
    log it as "Unverified Audio" for Setup_IQ rather than guessing.

    Keep every response to 1-2 short sentences. The racer is actively driving
    or moving — be fast, direct, and never conversational.

    When the racer ends the session, confirm the field report is on its way to
    Setup_IQ at the pit table.
    """

  // Spectre Scout_IQ endpoints (injected at build time via Secrets.swift)
  static var spectreTTSURL: String { Secrets.spectreTTSURL.trimmingCharacters(in: .whitespacesAndNewlines) }
  static var spectreScoutURL: String { Secrets.spectreScoutURL.trimmingCharacters(in: .whitespacesAndNewlines) }
  static var spectreActiveSessionURL: String {
    let base = spectreScoutURL
    return base.hasSuffix("/active-session") ? base : base + "/active-session"
  }
  static var spectreUserToken: String { Secrets.spectreUserToken.trimmingCharacters(in: .whitespacesAndNewlines) }

  // User-configurable values
  static var apiKey: String { SettingsManager.shared.geminiAPIKey }

  static func websocketURL() -> URL? {
    guard apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty else { return nil }
    return URL(string: "\(websocketBaseURL)?key=\(apiKey)")
  }

  static var isConfigured: Bool {
    return apiKey != "YOUR_GEMINI_API_KEY" && !apiKey.isEmpty
  }

  static var isSpectreConfigured: Bool {
    return spectreUserToken != "YOUR_SPECTRE_USER_TOKEN"
      && !spectreUserToken.isEmpty
      && spectreTTSURL.hasPrefix("http")
  }
}
