import AVFoundation

/// Short spoken prompts from the phone itself (not Gemini): the fold-to-end
/// countdown and the idle guard. `onPhoneSpeaker` routes the prompt to the
/// phone speaker, because folded glasses may have dropped their audio.
final class SpokenCues: NSObject, AVSpeechSynthesizerDelegate {
  static let shared = SpokenCues()

  private let synthesizer = AVSpeechSynthesizer()
  private var overrodeSpeaker = false

  var isSpeaking: Bool { synthesizer.isSpeaking }

  override private init() {
    super.init()
    synthesizer.delegate = self
  }

  func speak(_ text: String, onPhoneSpeaker: Bool = false) {
    if onPhoneSpeaker {
      overrodeSpeaker = (try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)) != nil
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate
    synthesizer.speak(utterance)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    // Put the route back unless the owner chose the phone speaker in Settings.
    guard overrodeSpeaker, !synthesizer.isSpeaking else { return }
    overrodeSpeaker = false
    if !SettingsManager.shared.speakerOutputEnabled {
      try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
    }
  }
}
