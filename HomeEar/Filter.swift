import Foundation

struct RequestFilter {
    let allowed: Bool
    let reason: String
    static func check(_ text: String, strict: Bool) -> RequestFilter {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = value.split(whereSeparator: \.isWhitespace)
        guard value.count >= 12, words.count >= 3, value.count <= 400 else {
            return .init(allowed: false, reason: "Too short or long")
        }
        let lower = value.lowercased()
        let commands = ["poke", "bitte", "mach", "schalte", "stelle", "öffne", "starte", "spiel", "zeig", "such", "erinnere", "kannst du", "könntest du", "wäre schön", "wär schön", "ich hätte gern", "ich möchte", "turn", "switch", "set", "show", "can you", "could you", "please", "i wish", "it would be nice"]
        let contextual = ["licht", "lampe", "heller", "dunkler", "heizung", "raum", "zimmer", "musik", "kalender", "mail", "wetter", "lights", "room", "temperature", "reminder", "calendar"]
        let starts = commands.contains(where: { lower.hasPrefix($0) })
        let context = contextual.contains(where: { lower.contains($0) })
        let score = starts && context || lower.hasPrefix("poke")
        if score { return .init(allowed: true, reason: "Matched request") }
        if !strict && starts { return .init(allowed: true, reason: "Possible request") }
        return .init(allowed: false, reason: "Background speech filtered")
    }
}
