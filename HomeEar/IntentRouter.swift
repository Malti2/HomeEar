import Foundation

enum Backend: String, Equatable {
    case poke
    case homeAssistant = "home_assistant"
}

struct RoutingDecision: Equatable {
    let backend: Backend
    let reason: String
}

/// Smart routing: one request, one backend, decided from the words alone.
/// Assistant topics (reminders, timers, calendar, weather, time) win over device
/// words, so "erinner mich das Licht auszumachen" is a reminder, not a light switch.
enum IntentRouter {
    static func route(_ text: String, extraDeviceWords: Set<String> = [], fallback: Backend) -> RoutingDecision {
        if let topic = RequestFilter.assistantTopic(in: text) {
            return RoutingDecision(backend: .poke, reason: "assistant topic: \(topic)")
        }
        if let device = RequestFilter.deviceWord(in: text, extra: extraDeviceWords) {
            return RoutingDecision(backend: .homeAssistant, reason: "device: \(device)")
        }
        return RoutingDecision(backend: fallback, reason: "unclear, using the default")
    }
}
