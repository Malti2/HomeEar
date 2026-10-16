import Foundation

/// Requests that open a lock, a garage, an alarm system or a heat source.
/// A misheard light is an annoyance; these are not. Such requests are never
/// sent from background speech, and with the wake word they ask first.
enum SensitiveActions {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// The first sensitive word or phrase found in `text`, or nil.
    static func match(in text: String, extra: Set<String> = []) -> String? {
        let tokens = text.lowercased(with: posix)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        if let hit = tokens.first(where: { alwaysSensitive.contains($0) || extra.contains($0) }) { return hit }
        // A door is only sensitive when asked to open ("Tür öffnen"), not when merely mentioned.
        if let door = tokens.first(where: { doors.contains($0) }), tokens.contains(where: { openers.contains($0) }) {
            return door
        }
        return nil
    }

    private static let alwaysSensitive: Set<String> = [
        "aufschließen", "aufschliessen", "aufschließe", "aufschliesse", "entriegeln", "entriegle",
        "aufsperren", "türschloss", "schloss", "tresor",
        "garage", "garagentor", "garagentür",
        "alarmanlage", "scharf", "unscharf",
        "herd", "backofen", "ofen", "kochfeld", "herdplatte",
        "unlock", "disarm", "deadbolt", "oven", "stove", "cooktop",
    ]

    private static let doors: Set<String> = [
        "tür", "türen", "haustür", "eingangstür", "wohnungstür", "terrassentür", "door", "doors",
    ]

    private static let openers: Set<String> = [
        "öffne", "öffnen", "auf", "aufmachen", "aufzumachen", "open",
    ]
}
