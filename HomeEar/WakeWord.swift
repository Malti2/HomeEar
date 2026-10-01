import Foundation

/// Detects the "Hey Poke" activation phrase in live transcription text.
///
/// HomeEar already runs continuous on-device transcription, so the wake word
/// is detected as text: no extra model, no extra battery drain, fully
/// private. Matching is fuzzy — the transcriber often renders the phrase as
/// "hey poak", "hey pouk", "ey poke", … — so tokens are compared with a small
/// edit distance instead of requiring an exact string.
///
/// No detector is literally 100%, but an explicit phrase plus fuzzy matching
/// on every partial result is as close as on-device gets. A lone "Hey Poke"
/// arms the router's command-capture mode (see UtteranceRouter), which closes
/// the loop even when the command comes in a separate utterance.
struct WakeWordDetector {
    struct Match {
        /// Range of the wake phrase inside the searched text.
        let range: Range<String.Index>
        /// Spoken text after the wake phrase (may be empty).
        let commandText: String
    }

    private struct Token {
        let word: String // lowercased
        let range: Range<String.Index>
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let heyWords: Set<String> = ["hey", "hei", "hay", "ey"]

    /// The first wake-phrase match in `text`, or nil.
    static func detect(in text: String) -> Match? {
        let tokens = tokenize(text)
        for i in tokens.indices {
            let word = tokens[i].word
            if isHey(word) {
                // Allow one filler token between the words ("hey, äh, poke").
                for j in [i + 1, i + 2] where j < tokens.endIndex {
                    if isPoke(tokens[j].word) {
                        let range = tokens[i].range.lowerBound ..< tokens[j].range.upperBound
                        return Match(range: range, commandText: commandAfter(text, range.upperBound))
                    }
                }
            } else if i == 0 && isPoke(word) {
                // Legacy: a bare leading "poke" (the old prefix trigger).
                let range = tokens[i].range
                return Match(range: range, commandText: commandAfter(text, range.upperBound))
            }
        }
        return nil
    }

    /// The text after a *leading* wake phrase, or nil if `text` doesn't start
    /// with one. Used to score the command part in the proactive filter.
    static func stripLeadingWakeWord(from text: String) -> String? {
        guard let match = detect(in: text) else { return nil }
        let prefix = text[..<match.range.lowerBound]
        guard prefix.allSatisfy({ $0.isWhitespace || $0.isPunctuation }) else { return nil }
        return match.commandText
    }

    // MARK: - private

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var wordStart: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            if ch.isLetter || ch.isNumber {
                if wordStart == nil { wordStart = index }
            } else if let start = wordStart {
                let range = start ..< index
                tokens.append(Token(word: String(text[range]).lowercased(with: posix), range: range))
                wordStart = nil
            }
            index = text.index(after: index)
        }
        if let start = wordStart {
            let range = start ..< text.endIndex
            tokens.append(Token(word: String(text[range]).lowercased(with: posix), range: range))
        }
        return tokens
    }

    private static func isHey(_ word: String) -> Bool {
        if heyWords.contains(word) { return true }
        return word.count >= 3 && levenshtein(word, "hey") <= 1
    }

    private static func isPoke(_ word: String) -> Bool {
        if word == "poke" { return true }
        guard word.count >= 3, let first = word.first, first == "p" || first == "b" else { return false }
        return levenshtein(word, "poke") <= 2
    }

    private static func commandAfter(_ text: String, _ index: String.Index) -> String {
        var result = String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
        while let first = result.first, first.isPunctuation {
            result.removeFirst()
            result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0 ... b.count)
        for i in 1 ... a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1 ... b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}
