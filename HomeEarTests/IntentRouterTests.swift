import XCTest
@testable import HomeEar

final class IntentRouterTests: XCTestCase {
    private func backend(_ text: String, extra: Set<String> = [], fallback: Backend = .poke) -> Backend {
        IntentRouter.route(text, extraDeviceWords: extra, fallback: fallback).backend
    }

    func testDeviceCommandsGoToHomeAssistant() {
        for text in ["mach das licht im wohnzimmer an", "schalte die heizung auf zwanzig grad", "dimm die lampe im bad",
                     "turn off the kitchen lights", "öffne die rollläden", "mach die musik leiser",
                     "stell die temperatur im schlafzimmer höher"] {
            XCTAssertEqual(backend(text), .homeAssistant, text)
        }
    }

    func testAssistantTopicsGoToPoke() {
        for text in ["wie wird das wetter morgen", "erinner mich um acht an den termin", "stell einen timer auf zehn minuten",
                     "what's on my calendar today", "wie spät ist es", "stell den wecker auf sieben uhr",
                     "will it rain tomorrow, what is the weather"] {
            XCTAssertEqual(backend(text, fallback: .homeAssistant), .poke, text)
        }
    }

    func testAssistantTopicBeatsDeviceWord() {
        XCTAssertEqual(backend("erinner mich das licht auszumachen"), .poke)
        XCTAssertEqual(backend("remind me to turn off the lights"), .poke)
    }

    func testUnclearRequestsUseTheFallback() {
        let text = "wer hat den ersten weltkrieg gewonnen"
        XCTAssertEqual(backend(text, fallback: .poke), .poke)
        XCTAssertEqual(backend(text, fallback: .homeAssistant), .homeAssistant)
        XCTAssertEqual(IntentRouter.route(text, fallback: .poke).reason, "unclear, using the default")
    }

    func testYourOwnAndImportedWordsCount() {
        XCTAssertEqual(backend("mach den pizzaofen an"), .poke)
        XCTAssertEqual(backend("mach den pizzaofen an", extra: ["pizzaofen"]), .homeAssistant)
        XCTAssertEqual(backend("mach die lesecke heller", extra: ["lesecke"], fallback: .poke), .homeAssistant)
    }

    func testReasonsNameTheWordThatDecided() {
        XCTAssertEqual(IntentRouter.route("mach das licht an", fallback: .poke).reason, "device: licht")
        XCTAssertEqual(IntentRouter.route("wie wird das wetter", fallback: .poke).reason, "assistant topic: wetter")
    }

    func testCompoundDeviceWordsMatch() {
        XCTAssertEqual(backend("mach die stehlampe an"), .homeAssistant)
    }
}
