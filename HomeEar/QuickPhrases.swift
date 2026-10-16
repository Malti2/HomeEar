import Foundation

/// A personal shortcut: say `trigger`, HomeEar sends `text` to the backend.
/// "Gute Nacht" → "Schalte alle Lichter aus und stell die Heizung auf 17 Grad".
struct QuickPhrase: Codable, Equatable, Identifiable {
    var id = UUID()
    var trigger = ""
    var text = ""
    /// Safer default: a bare phrase from background speech never triggers anything.
    var needsWakeWord = true
}

enum QuickPhrases {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Lowercase words only, so punctuation and capitalisation from the transcriber don't matter.
    static func normalize(_ text: String) -> String {
        text.lowercased(with: posix)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// The shortcut whose trigger is the *whole* utterance. Substrings never match,
    /// so "ich sage gute nacht zu den Kindern" does nothing.
    static func match(_ utterance: String, wakeWordUsed: Bool, in phrases: [QuickPhrase]) -> QuickPhrase? {
        let key = normalize(utterance)
        guard !key.isEmpty else { return nil }
        return phrases.first { phrase in
            !phrase.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && normalize(phrase.trigger) == key
                && (wakeWordUsed || !phrase.needsWakeWord)
        }
    }
}
