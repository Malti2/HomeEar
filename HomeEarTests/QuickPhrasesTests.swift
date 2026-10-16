import XCTest
@testable import HomeEar

private let goodNight = QuickPhrase(trigger: "Gute Nacht", text: "Schalte alle Lichter aus", needsWakeWord: true)
private let leaving = QuickPhrase(trigger: "Ich gehe jetzt", text: "Heizung runter und Lichter aus", needsWakeWord: false)

final class QuickPhrasesTests: XCTestCase {
    func testNormalizeIgnoresCaseAndPunctuation() {
        XCTAssertEqual(QuickPhrases.normalize("Gute Nacht!"), "gute nacht")
        XCTAssertEqual(QuickPhrases.normalize("  Ich   gehe, jetzt. "), "ich gehe jetzt")
    }

    func testMatchesTheWholeSentenceOnly() {
        XCTAssertEqual(QuickPhrases.match("gute nacht", wakeWordUsed: true, in: [goodNight])?.text, "Schalte alle Lichter aus")
        XCTAssertNil(QuickPhrases.match("ich sage gute nacht zu den kindern", wakeWordUsed: true, in: [goodNight]))
        XCTAssertNil(QuickPhrases.match("gute nacht zusammen", wakeWordUsed: true, in: [goodNight]))
    }

    func testWakeWordRequirement() {
        XCTAssertNil(QuickPhrases.match("gute nacht", wakeWordUsed: false, in: [goodNight]))
        XCTAssertNotNil(QuickPhrases.match("ich gehe jetzt", wakeWordUsed: false, in: [leaving]))
        XCTAssertNotNil(QuickPhrases.match("ich gehe jetzt", wakeWordUsed: true, in: [leaving]))
    }

    func testIncompleteShortcutsNeverMatch() {
        XCTAssertNil(QuickPhrases.match("gute nacht", wakeWordUsed: true, in: [QuickPhrase(trigger: "gute nacht", text: "  ")]))
        XCTAssertNil(QuickPhrases.match("", wakeWordUsed: true, in: [QuickPhrase(trigger: "", text: "x")]))
    }

    func testRoundTripsThroughJSON() throws {
        let data = try JSONEncoder().encode([goodNight, leaving])
        XCTAssertEqual(try JSONDecoder().decode([QuickPhrase].self, from: data), [goodNight, leaving])
    }
}

final class ShortcutRouterTests: XCTestCase {
    private struct Outcome {
        var delivered: [(text: String, source: FilterSource)] = []
        var asked: [PendingRequest] = []
    }

    private func run(phrases: [QuickPhrase], _ body: @MainActor (UtteranceRouter) -> Void) async -> Outcome {
        await MainActor.run {
            let router = UtteranceRouter()
            router.config.quickPhrases = phrases
            var outcome = Outcome()
            router.onDeliver = { outcome.delivered.append(($0, $1)) }
            router.onAskBack = { outcome.asked.append($0) }
            body(router)
            return outcome
        }
    }

    func testWakeWordShortcut() async {
        let outcome = await run(phrases: [goodNight]) { $0.receive("hey poke gute nacht", isFinal: true) }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["Schalte alle Lichter aus"])
        XCTAssertEqual(outcome.delivered.first?.source, .shortcut)
    }

    func testShortcutInTheNextUtteranceAfterALoneWakeWord() async {
        let outcome = await run(phrases: [goodNight]) {
            $0.receive("hey poke", isFinal: true)
            $0.receive("gute nacht", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["Schalte alle Lichter aus"])
    }

    func testBareShortcutOnlyWorksWhenAllowed() async {
        let blocked = await run(phrases: [goodNight]) { $0.receive("gute nacht", isFinal: true) }
        XCTAssertTrue(blocked.delivered.isEmpty)
        let allowed = await run(phrases: [leaving]) { $0.receive("ich gehe jetzt", isFinal: true) }
        XCTAssertEqual(allowed.delivered.map { $0.text }, ["Heizung runter und Lichter aus"])
        XCTAssertEqual(allowed.delivered.first?.source, .shortcut)
    }

    func testShortcutWinsOverAnOpenFollowUpWindow() async {
        let outcome = await run(phrases: [leaving]) {
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("ich gehe jetzt", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["Heizung runter und Lichter aus"])
    }

    func testShortcutTextStillPassesTheSafetyGate() async {
        let garage = QuickPhrase(trigger: "Ich bin da", text: "Mach das Garagentor auf", needsWakeWord: true)
        let outcome = await run(phrases: [garage]) { $0.receive("hey poke ich bin da", isFinal: true) }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertEqual(outcome.asked.count, 1)
    }

    func testPartialsDoNotRunShortcuts() async {
        let outcome = await run(phrases: [leaving]) { $0.receive("ich gehe jetzt", isFinal: false) }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testOrdinaryCommandsAreUnaffected() async {
        let outcome = await run(phrases: [goodNight, leaving]) { $0.receive("hey poke mach das licht an", isFinal: true) }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["mach das licht an"])
        XCTAssertEqual(outcome.delivered.first?.source, .wakeWord)
    }
}
