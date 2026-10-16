import Foundation

/// What the menu bar icon shows. A Mac that listens all day needs to say
/// whether it is idle, waiting for you, or has just done something.
enum AssistantPhase: Equatable {
    case paused, listening, capturing, sent, error

    var symbol: String {
        switch self {
        case .paused: "waveform.slash"
        case .listening: "waveform"
        case .capturing: "mic.fill"
        case .sent: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    /// A short-lived result (sent, error) wins over the steady state.
    static func resolve(microphoneOn: Bool, capturing: Bool, flash: AssistantPhase?) -> AssistantPhase {
        if let flash { return flash }
        if !microphoneOn { return .paused }
        return capturing ? .capturing : .listening
    }
}

/// Optional sounds, off by default. System sounds keep the app free of audio assets.
enum SoundCue: Equatable {
    /// HomeEar now waits for you: a command after "Hey Poke", an answer, a confirmation.
    case heard
    case sent
    case error

    var systemSoundName: String {
        switch self {
        case .heard: "Tink"
        case .sent: "Pop"
        case .error: "Basso"
        }
    }
}
