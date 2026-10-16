import Foundation

/// Where an accepted request came from.
enum FilterSource: String {
    case wakeWord = "Wake word"
    case proactive = "Proactive filter"
    case followUp = "Follow-up"
}

enum FilterDecision {
    case accept(source: FilterSource, reason: String)
    /// One point short and command-shaped: worth asking about instead of guessing.
    case uncertain(reason: String)
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
///   +2  infinitive command, no imperative   ("das Licht bitte anmachen")
///   +1  question about a known entity       ("wie wird das Wetter?")
///   −2  starts with a subject pronoun       ("er will das Licht anmachen"),
///       unless a polite framing is present  ("ich möchte …")
///   −2  starts a subordinate clause         ("wenn du das Licht anmachst …")
///   −2  past-tense marker                   ("hat das Licht angemacht")
///   −2  sounds far from the microphone     (TV, radio, another room)
///   −4  addressed to a person               ("Mama, mach das Licht aus"),
///       built-in family words plus the household names the user adds
///   −3  laughter / non-speech tokens
///
/// Strict mode needs 4 points, relaxed 3. Length gates stay: 12–400 chars,
/// at least 3 words. Verb matching is token-exact on purpose: "mach" scores,
/// "macht" ("er macht das Licht an" — talking *about* someone) does not.
/// Entities are matched per token: exactly, or as the tail of a German
/// compound ("wohnzimmerlampe" → "lampe"). Short entities ("raum", "tür")
/// never match inside longer words, otherwise "natürlich" or "traum" would
/// look like smart-home talk. Users can add their own entities (`extra`).
/// A leading wake phrase is stripped before scoring so "Hey Poke, mach …"
/// is judged on the command itself.
struct RequestFilter {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func checkProactive(_ text: String, strict: Bool, extra: Set<String> = [],
                               addressees: Set<String> = [], audio: AudioCue = .normal) -> FilterDecision {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = value.split(whereSeparator: \.isWhitespace)
        guard value.count >= 12, words.count >= 3, value.count <= 400 else {
            return .reject(reason: "Too short or long")
        }
        let command = WakeWordDetector.stripLeadingWakeWord(from: value) ?? value
        let lower = command.lowercased(with: posix)
        // Punctuation splits tokens ("licht, bitte"); apostrophes stay ("what's").
        let tokens = lower.split(whereSeparator: isSeparator).map(String.init)

        var score = 0
        var hits: [String] = []
        if let first = tokens.first, verbs.contains(first) {
            score += 3; hits.append("verb")
        } else if tokens.prefix(3).contains(where: { verbs.contains($0) }) {
            score += 2; hits.append("verb")
        }
        let hasEntity = mentionsEntity(tokens, extra: extra)
        let isPolite = polite.contains(where: { lower.contains($0) })
        if !hits.contains("verb"), mentionsInfinitive(tokens) {
            score += 2; hits.append("infinitive")
        }
        if hasEntity { score += 2; hits.append("entity") }
        if isPolite { score += 2; hits.append("polite") }
        if hasEntity, questionStarts.contains(where: { lower.hasPrefix($0) }) {
            score += 1; hits.append("question")
        }
        if !isPolite, let first = tokens.first, subjects.contains(first) { score -= 2 }
        if let first = tokens.first, subordinators.contains(first) { score -= 2 }
        if tokens.contains(where: { pastMarkers.contains($0) }) { score -= 2 }
        if let first = tokens.first, let last = tokens.last,
           [first, last].contains(where: { vocatives.contains($0) || addressees.contains($0) }) {
            score -= 4
        }
        if tokens.contains(where: { anti.contains($0) }) { score -= 3 }
        // Audio only ever lowers the score: loud speech alone is no reason to forward.
        if audio == .far { score -= 2 }

        let threshold = strict ? 4 : 3
        if score >= threshold {
            return .accept(source: .proactive, reason: "Score \(score) (\(hits.joined(separator: "+")))")
        }
        let commandShaped = hits.contains { ["verb", "infinitive", "polite", "question"].contains($0) }
        if score == threshold - 1, hits.contains("entity"), commandShaped {
            return .uncertain(reason: "Score \(score) (\(hits.joined(separator: "+")))")
        }
        return .reject(reason: "Background speech filtered (score \(score))")
    }

    /// Short utterance right after a spoken reply that reads like a continuation
    /// ("und im Flur auch", "mach es heller") rather than background talk.
    static func looksLikeFollowUp(_ text: String, extra: Set<String> = []) -> Bool {
        let tokens = text.lowercased(with: posix).split(whereSeparator: isSeparator).map(String.init)
        guard !tokens.isEmpty, tokens.count <= 8 else { return false }
        if let first = tokens.first, subjects.contains(first) { return false }
        if tokens.contains(where: { pastMarkers.contains($0) }) { return false }
        if let first = tokens.first, connectors.contains(first) { return true }
        let hasEntity = mentionsEntity(tokens, extra: extra)
        if tokens.prefix(3).contains(where: { verbs.contains($0) }) { return true }
        // "machen" alone is everyday talk; an infinitive only counts next to a device or room.
        if hasEntity, mentionsInfinitive(tokens) { return true }
        // A bare room or device name ("im Flur") is fine, a whole sentence about one is not.
        return tokens.count <= 4 && hasEntity
    }

    private static let connectors: Set<String> = [
        "und", "auch", "noch", "dann", "aber", "außerdem", "and", "also", "then", "now",
    ]

    /// Splits a user-entered keyword list ("ventilator, kamin garage") into
    /// lowercase single tokens.
    static func parseKeywords(_ text: String) -> Set<String> {
        Set(text.lowercased(with: posix)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { $0.count >= 2 })
    }

    /// Infinitive command, also when the transcriber splits the particle off
    /// ("an machen" instead of "anmachen").
    private static func mentionsInfinitive(_ tokens: [String]) -> Bool {
        if tokens.contains(where: { infinitives.contains($0) }) { return true }
        return zip(tokens, tokens.dropFirst()).contains { infinitives.contains($0 + $1) }
    }

    /// Turns Home Assistant device and room names ("Stehlampe Ecke", "Büro")
    /// into filter words. Numbers, tiny words and common function words are
    /// dropped so a name like "Hue Go 1" doesn't make "go" an entity.
    static func vocabularyWords(from names: [String], limit: Int = 500) -> Set<String> {
        var words = Set<String>()
        for name in names {
            let tokens = name.lowercased(with: posix)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            for token in tokens where token.count >= 3 && !token.allSatisfy(\.isNumber)
                && !vocabularyStopWords.contains(token) {
                words.insert(token)
                if words.count >= limit { return words }
            }
        }
        return words
    }

    private static let vocabularyStopWords: Set<String> = [
        "der", "die", "das", "und", "von", "mit", "ein", "eine", "ist", "the", "and", "for", "all", "alle",
    ]

    private static func isSeparator(_ character: Character) -> Bool {
        !(character.isLetter || character.isNumber || character == "'" || character == "’")
    }

    private static func mentionsEntity(_ tokens: [String], extra: Set<String>) -> Bool {
        tokens.contains { token in
            if entities.contains(token) || extra.contains(token) { return true }
            // Compound tail, only for words long enough to be unambiguous.
            func tail(_ word: String) -> Bool {
                word.count >= 5 && token.count > word.count && token.hasSuffix(word)
            }
            return entities.contains(where: tail) || extra.contains(where: tail)
        }
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
        "erzähl", "erzähle", "weck", "lösch", "lösche", "wechsel", "wechsle",
        "pausier", "pausiere", "verdunkel", "verdunkle", "heiz", "heize",
        "kühl", "kühle",
        "turn", "switch", "set", "dim", "open", "close",
        "play", "lock", "unlock", "raise", "lower", "remind",
        "stop", "pause", "increase", "decrease", "activate", "deactivate", "show",
    ]

    /// Infinitive commands ("das Licht bitte anmachen"), common in spoken German.
    private static let infinitives: Set<String> = [
        "anmachen", "ausmachen", "einschalten", "ausschalten", "anschalten",
        "abschalten", "aufmachen", "zumachen", "öffnen", "schließen",
        "dimmen", "starten", "stoppen", "pausieren", "abspielen",
        "hochfahren", "runterfahren", "herunterfahren", "aufdrehen",
        "runterdrehen", "herunterdrehen", "ausstellen", "anstellen",
        "stellen", "einstellen", "erhöhen", "senken", "reduzieren", "machen",
    ]

    /// Clause openers: the sentence is *about* an action, not a request.
    private static let subordinators: Set<String> = [
        "wenn", "dass", "weil", "ob", "obwohl", "damit", "falls",
        "if", "because", "although",
    ]

    /// Auxiliaries that put the action in the past ("hat das Licht angemacht").
    private static let pastMarkers: Set<String> = [
        "hat", "hast", "habe", "hatte", "war", "waren", "wurde", "wurden",
        "had", "were", "did", "has",
    ]

    /// Family words and pet names: at the start or end they mean the request
    /// is for someone in the room, not for HomeEar.
    private static let vocatives: Set<String> = [
        "schatz", "schatzi", "liebling", "mama", "mami", "mutti", "papa", "papi",
        "oma", "opa", "honey", "babe", "mom", "mum", "dad", "darling",
    ]

    /// Sentence-initial subjects that usually mean "talking about", not "asking".
    private static let subjects: Set<String> = [
        "er", "sie", "es", "wir", "ihr", "ich", "he", "she", "they", "we", "i",
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
        "badezimmer", "garage", "garagentor", "rollo", "rollos", "rolladen",
        "ventilator", "kamin", "klimaanlage", "lüftung", "radio", "lautsprecher",
        "alarmanlage", "heizkörper", "stehlampe", "balkon", "terrasse", "keller",
        "fan", "speaker", "doorbell",
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
