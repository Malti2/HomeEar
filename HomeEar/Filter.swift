import Foundation

/// Where an accepted request came from.
enum FilterSource: String {
    case wakeWord = "Wake word"
    case proactive = "Proactive filter"
}

enum FilterDecision {
    case accept(source: FilterSource, reason: String)
    case reject(reason: String)
}

/// Layered, deterministic request filter for the proactive path — utterances
/// *without* an explicit "Hey Poke".
///
/// Scoring (German + English):
///   +3  starts with an imperative verb      ("mach das Licht an")
///   +2  verb within the first three tokens ("bitte mach das Licht an")
///   +2  mentions a smart-home entity        ("… das Licht …")
///   +2  polite request pattern              ("kannst du …", "please …")
///   +1  question about a known entity       ("wie wird das Wetter?")
///   −3  laughter / non-speech tokens
///
/// Strict mode needs 4 points, relaxed 3. Length gates stay: 12–400 chars,
/// at least 3 words. Verb matching is token-exact on purpose: "mach" scores,
/// "macht" ("er macht das Licht an" — talking *about* someone) does not.
/// A leading wake phrase is stripped before scoring so "Hey Poke, mach …"
/// is judged on the command itself.
struct RequestFilter {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func checkProactive(_ text: String, strict: Bool) -> FilterDecision {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = value.split(whereSeparator: \.isWhitespace)
        guard value.count >= 12, words.count >= 3, value.count <= 400 else {
            return .reject(reason: "Too short or long")
        }
        let command = WakeWordDetector.stripLeadingWakeWord(from: value) ?? value
        let lower = command.lowercased(with: posix)
        let tokens = lower.split(whereSeparator: \.isWhitespace).map(String.init)

        var score = 0
        var hits: [String] = []
        if let first = tokens.first, verbs.contains(first) {
            score += 3; hits.append("verb")
        } else if tokens.prefix(3).contains(where: { verbs.contains($0) }) {
            score += 2; hits.append("verb")
        }
        if entities.contains(where: { lower.contains($0) }) { score += 2; hits.append("entity") }
        if polite.contains(where: { lower.contains($0) }) { score += 2; hits.append("polite") }
        if questionStarts.contains(where: { lower.hasPrefix($0) }),
           entities.contains(where: { lower.contains($0) }) {
            score += 1; hits.append("question")
        }
        if tokens.contains(where: { anti.contains($0) }) { score -= 3 }

        let threshold = strict ? 4 : 3
        if score >= threshold {
            return .accept(source: .proactive, reason: "Score \(score) (\(hits.joined(separator: "+")))")
        }
        return .reject(reason: "Background speech filtered (score \(score))")
    }

    // MARK: - lexicons

    /// Imperative verb forms, matched token-exact (see doc comment above).
    private static let verbs: Set<String> = [
        "mach", "mache", "schalt", "schalte", "stell", "stelle",
        "öffne", "öffn", "schließ", "schließe", "start", "starte",
        "stopp", "stoppe", "spiel", "spiele", "zeig", "zeige",
        "such", "suche", "erinner", "erinnere", "dimm", "dimme",
        "dreh", "drehe", "erhöh", "erhöhe", "senk", "senke",
        "aktivier", "aktiviere", "deaktivier", "deaktiviere",
        "fahr", "fahre", "leg", "lege", "lies", "sag", "sage",
        "erzähl", "erzähle", "weck",
        "turn", "switch", "set", "dim", "open", "close",
        "play", "lock", "unlock", "raise", "lower", "remind",
    ]

    /// Smart-home and everyday entities that make an utterance command-like.
    private static let entities: Set<String> = [
        "licht", "lichter", "lampe", "lampen", "heller", "dunkler", "dunkel",
        "heizung", "thermostat", "temperatur", "wärmer", "kälter", "kühler",
        "raum", "zimmer", "wohnzimmer", "schlafzimmer", "küche", "bad", "flur",
        "arbeitszimmer", "rollladen", "rollläden", "jalousie", "jalousien",
        "steckdose", "steckdosen", "szene", "szenen", "musik", "lautstärke",
        "lauter", "leiser", "laut", "leise", "wetter", "regen", "sonne",
        "kalender", "termin", "termine", "erinnerung", "wecker", "timer",
        "tür", "türen", "fenster", "kaffee", "saugroboter", "fernseher", "tv",
        "uhr", "spät",
        "light", "lights", "lamp", "heating", "temperature", "room",
        "bedroom", "kitchen", "bathroom", "blinds", "shutter", "plug",
        "scene", "music", "volume", "weather", "calendar", "appointment",
        "reminder", "alarm", "door", "window", "warmer", "cooler",
        "brighter", "dimmer",
    ]

    /// Polite request framings.
    private static let polite: Set<String> = [
        "kannst du", "könntest du", "könntest", "wäre schön", "wär schön",
        "wäre toll", "wär toll", "ich hätte gern", "ich möchte", "bitte",
        "can you", "could you", "would you", "please",
        "i'd like", "i would like", "it would be nice",
    ]

    /// Question openers that are worth forwarding when they ask about an entity.
    private static let questionStarts: Set<String> = [
        "wie ist", "wie wird", "was ist", "was sind", "gibt es", "wann",
        "wie spät", "what is", "what's", "how is", "is there", "when is",
        "what time",
    ]

    /// Tokens that mark an utterance as non-speech.
    private static let anti: Set<String> = ["haha", "hehe", "hihi", "hoho"]
}
