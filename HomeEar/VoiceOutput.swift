import Foundation
import AVFoundation

@MainActor final class VoiceOutput: NSObject {
    weak var state: AppState?
    private let synthesizer = AVSpeechSynthesizer()
    init(state: AppState) {
        self.state = state
        super.init()
    }
    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: state?.voiceID ?? "") ?? AVSpeechSynthesisVoice(language: "de-DE")
        synthesizer.speak(utterance)
        state?.ttsState = "Speaking"
    }
}
