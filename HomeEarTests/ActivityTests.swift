import XCTest
@testable import HomeEar

final class ActivityLogTests: XCTestCase {
    private func entry(_ text: String) -> ActivityEntry {
        ActivityEntry(date: Date(), text: text, outcome: .filtered, reason: "test", source: nil)
    }

    func testNewestFirstAndCapped() {
        var log = ActivityLog()
        for index in 0..<(ActivityLog.limit + 5) { log.add(entry("sentence \(index)")) }
        XCTAssertEqual(log.entries.count, ActivityLog.limit)
        XCTAssertEqual(log.entries.first?.text, "sentence \(ActivityLog.limit + 4)")
        XCTAssertEqual(log.entries.last?.text, "sentence 5")
    }

    func testClear() {
        var log = ActivityLog()
        log.add(entry("a"))
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }
}

final class FilterFeedbackTests: XCTestCase {
    func testKeyIgnoresCaseAndPunctuationAndIsNotReadable() {
        let key = FilterFeedback.key(for: "Mach das Licht an!")
        XCTAssertEqual(key, FilterFeedback.key(for: "mach das licht an"))
        XCTAssertEqual(key.count, 64)
        XCTAssertNil(key.range(of: "licht"))
    }

    func testRecordAndLookup() {
        var feedback = FilterFeedback()
        XCTAssertNil(feedback.verdict(for: "mach das licht an"))
        feedback.record(.send, for: "mach das licht an")
        XCTAssertEqual(feedback.verdict(for: "Mach das Licht an."), .send)
        XCTAssertEqual(feedback.count, 1)
    }

    func testLatestVerdictWins() {
        var feedback = FilterFeedback()
        feedback.record(.send, for: "irgendein satz hier")
        feedback.record(.ignore, for: "irgendein satz hier")
        XCTAssertEqual(feedback.verdict(for: "irgendein satz hier"), .ignore)
        XCTAssertEqual(feedback.count, 1)
    }

    func testOldestIsEvictedAtTheLimit() {
        var feedback = FilterFeedback()
        for index in 0..<(FilterFeedback.limit + 3) { feedback.record(.ignore, for: "satz nummer \(index)") }
        XCTAssertEqual(feedback.count, FilterFeedback.limit)
        XCTAssertNil(feedback.verdict(for: "satz nummer 0"))
        XCTAssertNotNil(feedback.verdict(for: "satz nummer \(FilterFeedback.limit + 2)"))
    }

    func testEmptySentencesAreNotRemembered() {
        var feedback = FilterFeedback()
        feedback.record(.send, for: "  !! ")
        XCTAssertEqual(feedback.count, 0)
    }

    func testSurvivesJSONWithoutContainingTheText() throws {
        var feedback = FilterFeedback()
        feedback.record(.send, for: "schalte den fernseher aus")
        let data = try JSONEncoder().encode(feedback)
        XCTAssertNil(String(decoding: data, as: UTF8.self).range(of: "fernseher"))
        let restored = try JSONDecoder().decode(FilterFeedback.self, from: data)
        XCTAssertEqual(restored.verdict(for: "schalte den fernseher aus"), .send)
    }

    func testRemoveAll() {
        var feedback = FilterFeedback()
        feedback.record(.send, for: "ein satz zum vergessen")
        feedback.removeAll()
        XCTAssertEqual(feedback.count, 0)
        XCTAssertNil(feedback.verdict(for: "ein satz zum vergessen"))
    }
}

final class ActivityRouterTests: XCTestCase {
    private struct Outcome {
        var delivered: [(text: String, source: FilterSource)] = []
        var events: [ActivityEntry] = []
    }

    private func run(_ body: @MainActor (UtteranceRouter) -> Void) async -> Outcome {
        await MainActor.run {
            let router = UtteranceRouter()
            var outcome = Outcome()
            router.onDeliver = { outcome.delivered.append(($0, $1)) }
            router.onEvent = { outcome.events.append($0) }
            body(router)
            return outcome
        }
    }

    func testRejectedChatterIsLoggedWithAReason() async {
        let outcome = await run { $0.receive("was hast du heute so gemacht", isFinal: true) }
        XCTAssertEqual(outcome.events.count, 1)
        XCTAssertEqual(outcome.events.first?.outcome, .filtered)
        XCTAssertTrue(outcome.events.first?.reason.contains("score") ?? false)
    }

    func testDistantSpeechSaysSo() async {
        let outcome = await run { $0.receive("mach das licht im flur an", isFinal: true, audio: AudioFeatures(snr: 5)) }
        XCTAssertTrue(outcome.events.contains { $0.reason.contains("distant") })
    }

    func testSensitiveBlockIsLogged() async {
        let outcome = await run { $0.receive("mach bitte den herd an", isFinal: true) }
        XCTAssertTrue(outcome.events.contains { $0.outcome == .filtered && $0.reason.contains("wake word") })
    }

    func testQuestionsAndAnswersAreLogged() async {
        let outcome = await run {
            $0.receive("wie wird das wetter morgen", isFinal: true)
            $0.receive("nein", isFinal: true)
        }
        XCTAssertEqual(outcome.events.map { $0.outcome }, [.asked, .cancelled])
    }

    func testDuplicatesAreLogged() async {
        let outcome = await run {
            $0.receive("mach das licht im flur an", isFinal: true)
            $0.receive("mach das licht im flur an", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.count, 1)
        XCTAssertEqual(outcome.events.map { $0.outcome }, [.duplicate])
    }

    func testLearnedIgnoreStopsASentenceThatWouldPass() async {
        let outcome = await run {
            $0.config.feedback.record(.ignore, for: "mach das licht im flur an")
            $0.receive("mach das licht im flur an", isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertEqual(outcome.events.first?.reason, "You marked this as not a command")
    }

    func testLearnedSendPassesASentenceTheFilterRejects() async {
        let sentence = "das war gestern wirklich ein schöner abend"
        let before = await run { $0.receive(sentence, isFinal: true) }
        XCTAssertTrue(before.delivered.isEmpty)
        let after = await run {
            $0.config.feedback.record(.send, for: sentence)
            $0.receive(sentence, isFinal: true)
        }
        XCTAssertEqual(after.delivered.map { $0.text }, [sentence])
        XCTAssertEqual(after.delivered.first?.source, .proactive)
    }

    func testLearnedSendDoesNotOverrideDistantSpeech() async {
        let sentence = "das war gestern wirklich ein schöner abend"
        let outcome = await run {
            $0.config.feedback.record(.send, for: sentence)
            $0.receive(sentence, isFinal: true, audio: AudioFeatures(snr: 5))
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testLearnedSendDoesNotOverrideTheSafetyGate() async {
        let sentence = "schalte den herd an"
        let outcome = await run {
            $0.config.feedback.record(.send, for: sentence)
            $0.receive(sentence, isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testSendManuallyDelivers() async {
        let outcome = await run { $0.sendManually("irgendein satz den der filter nicht mochte") }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["irgendein satz den der filter nicht mochte"])
    }

    func testSendManuallyStillAsksForSensitiveRequests() async {
        let outcome = await run { $0.sendManually("öffne das garagentor") }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertEqual(outcome.events.map { $0.outcome }, [.asked])
    }
}
