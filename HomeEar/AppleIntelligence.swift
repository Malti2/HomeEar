import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

enum IntelligenceAvailability: Equatable {
    case available
    case unavailable(String)

    var isAvailable: Bool { self == .available }

    var message: String {
        switch self {
        case .available: "Available on this Mac"
        case .unavailable(let reason): reason
        }
    }
}

#if canImport(FoundationModels)
/// What the on-device model has to answer: one yes or no.
@Generable
struct RequestVerdict {
    @Guide(description: "True if the speaker is giving the home assistant a command or asking it something. False for talk between people, talk about someone else, TV, radio or past events.")
    var isRequest: Bool
}
#endif

/// Optional second opinion for sentences that are almost a command. Runs on this Mac with
/// Apple's on-device model: nothing leaves the Mac, and the answer is a single boolean
/// with no tools attached, so an overheard sentence can't make it do anything.
enum AppleIntelligence {
    private static let instructions = """
        You help a smart-home voice assistant that listens through a microphone all day. \
        You get one sentence that was overheard, in German or English. Decide whether the speaker \
        is giving the assistant a command or asking it something about their home, calendar, \
        weather, reminders or similar. Conversation between people, talk about someone else, \
        TV or radio, and things that already happened are not requests.
        """

    static func availability() -> IntelligenceAvailability {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable("This Mac doesn't support Apple Intelligence")
            case .appleIntelligenceNotEnabled: return .unavailable("Turn on Apple Intelligence in System Settings")
            case .modelNotReady: return .unavailable("The on-device model is still getting ready")
            @unknown default: return .unavailable("Not available right now")
            }
        @unknown default:
            return .unavailable("Not available right now")
        }
        #else
        return .unavailable("Needs macOS 26 with Apple Intelligence")
        #endif
    }

    /// nil means no verdict: model unavailable, language not supported, refused or failed.
    static func isRequest(_ text: String) async -> Bool? {
        #if canImport(FoundationModels)
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(to: "Sentence: \"\(text)\"", generating: RequestVerdict.self,
                                                     options: GenerationOptions(sampling: .greedy))
            return response.content.isRequest
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
