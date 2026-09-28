import Foundation
import AVFoundation

@MainActor final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    weak var state: AppState?
    private let synthesizer = AVSpeechSynthesizer()
    init(state: AppState) {
        self.state = state
        super.init()
        synthesizer.delegate = self
    }
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: state?.voiceID ?? "") ?? AVSpeechSynthesisVoice(language: "de-DE")
        synthesizer.speak(utterance)
        state?.ttsState = "Speaking"
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        state?.ttsState = "Ready"
    }
}
