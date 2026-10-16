import Foundation

/// Tells the speech pipeline when to ignore the microphone because HomeEar
/// itself is talking. The transcriber hears the Mac's speaker like any other
/// sound; without this, a spoken reply could be routed as a new request.
/// Times are monotonic seconds (`ProcessInfo.systemUptime`), injected for tests.
struct EchoGuard: Equatable {
    /// Recognition lags behind the audio, so the guard outlives the speech a little.
    static let tail: TimeInterval = 1.2

    /// Safety net: if the synthesizer never reports back, the microphone must
    /// not stay muted forever.
    static let maxSpeaking: TimeInterval = 120

    private(set) var speaking = false
    private(set) var startedAt: TimeInterval = 0
    private(set) var quietUntil: TimeInterval = 0

    mutating func began(at now: TimeInterval) {
        speaking = true
        startedAt = now
    }

    mutating func ended(at now: TimeInterval) {
        speaking = false
        quietUntil = now + Self.tail
    }

    func shouldDrop(at now: TimeInterval) -> Bool {
        (speaking && now - startedAt < Self.maxSpeaking) || now < quietUntil
    }
}
