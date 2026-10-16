import Foundation
import AVFoundation

@MainActor final class VoiceOutput: NSObject, AVSpeechSynthesizerDelegate {
    weak var state: AppState?
    private let synthesizer = AVSpeechSynthesizer()
    /// Utterances handed to the synthesizer that haven't finished or been cancelled.
    private var outstanding = 0
    /// Whether the last thing we said was a question that expects an answer.
    private var lastExpectsAnswer = false

    init(state: AppState) {
        self.state = state
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String, expectsAnswer: Bool = false) {
        lastExpectsAnswer = expectsAnswer
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: state?.voiceID ?? "")
            ?? AVSpeechSynthesisVoice(language: state?.language ?? "de-DE")
        outstanding += 1
        state?.speechDidBegin()
        synthesizer.speak(utterance)
    }

    private func utteranceEnded() {
        outstanding = max(0, outstanding - 1)
        if outstanding == 0 { state?.speechDidEnd(expectsAnswer: lastExpectsAnswer) }
    }

    // AVFoundation calls these off the main actor; hop back before touching state.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in self?.utteranceEnded() }
    }
}
