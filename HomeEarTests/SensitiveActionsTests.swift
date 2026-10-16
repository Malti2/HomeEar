import XCTest
@testable import HomeEar

final class SensitiveActionsTests: XCTestCase {
    func testFlagsLocksGaragesAlarmsAndHeatSources() {
        for text in ["schließ die haustür auf", "mach die garage auf", "schalte den herd an",
                     "stell den backofen auf zweihundert grad", "unlock the front door",
                     "alarmanlage scharf schalten", "disarm the alarm", "öffne die tür"] {
            XCTAssertNotNil(SensitiveActions.match(in: text), text)
        }
    }

    func testLeavesEverydayRequestsAlone() {
        for text in ["mach das licht im flur an", "stell einen alarm auf sieben uhr", "die tür ist zu laut",
                     "dimm die lampe im bad", "play some music", "wie wird das wetter morgen"] {
            XCTAssertNil(SensitiveActions.match(in: text), text)
        }
    }

    func testUserWordsCount() {
        XCTAssertNil(SensitiveActions.match(in: "öffne die poolabdeckung"))
        XCTAssertEqual(SensitiveActions.match(in: "öffne die poolabdeckung", extra: ["poolabdeckung"]), "poolabdeckung")
    }
}

final class SafetyGateTests: XCTestCase {
    private struct Outcome {
        var delivered: [(text: String, source: FilterSource)] = []
        var asked: [PendingRequest] = []
        var decisions: [String] = []
    }

    private func run(_ body: @MainActor (UtteranceRouter) -> Void) async -> Outcome {
        await MainActor.run {
            let router = UtteranceRouter()
            var outcome = Outcome()
            router.onDeliver = { outcome.delivered.append(($0, $1)) }
            router.onAskBack = { outcome.asked.append($0) }
            router.onDecision = { outcome.decisions.append($0) }
            body(router)
            return outcome
        }
    }

    func testBackgroundSpeechNeverSendsSensitiveRequests() async {
        let outcome = await run { $0.receive("mach bitte den herd an", isFinal: true) }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertTrue(outcome.asked.isEmpty)
        XCTAssertTrue(outcome.decisions.contains { $0.contains("needs the wake word") })
    }

    func testBackgroundSpeechRuleHoldsEvenWithConfirmationSwitchedOff() async {
        let outcome = await run {
            $0.config.confirmSensitive = false
            $0.receive("mach bitte den herd an", isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testWakeWordAsksBeforeSending() async {
        let outcome = await run { $0.receive("hey poke schließ die haustür auf", isFinal: true) }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertEqual(outcome.asked.count, 1)
        XCTAssertTrue(outcome.asked.first?.sensitive ?? false)
    }

    func testYesSendsAfterConfirmation() async {
        let outcome = await run {
            $0.receive("hey poke schließ die haustür auf", isFinal: true)
            $0.receive("ja", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["schließ die haustür auf"])
        XCTAssertEqual(outcome.delivered.first?.source, .wakeWord)
    }

    func testNoAndPanelDiscardSendNothing() async {
        let no = await run {
            $0.receive("hey poke schließ die haustür auf", isFinal: true)
            $0.receive("nein", isFinal: true)
        }
        XCTAssertTrue(no.delivered.isEmpty)
        let discard = await run {
            $0.receive("hey poke schließ die haustür auf", isFinal: true)
            $0.discardPending()
        }
        XCTAssertTrue(discard.delivered.isEmpty)
    }

    func testConfirmationCanBeSwitchedOffForTheWakeWord() async {
        let outcome = await run {
            $0.config.confirmSensitive = false
            $0.receive("hey poke schließ die haustür auf", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.count, 1)
        XCTAssertTrue(outcome.asked.isEmpty)
    }

    func testSensitiveQuestionsAreNotSubjectToTheCooldown() async {
        let outcome = await run {
            $0.receive("hey poke öffne die garage", isFinal: true)
            $0.discardPending()
            $0.receive("hey poke öffne die garage", isFinal: true)
        }
        XCTAssertEqual(outcome.asked.count, 2)
    }

    func testFollowUpsAreGatedToo() async {
        let outcome = await run {
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("die garage öffnen", isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertEqual(outcome.asked.count, 1)
    }

    func testUserWordsAreHonouredByTheGate() async {
        let outcome = await run {
            $0.config.extraSensitive = ["poolabdeckung"]
            $0.receive("hey poke öffne die poolabdeckung", isFinal: true)
        }
        XCTAssertEqual(outcome.asked.count, 1)
    }

    func testEverydayWakeWordCommandsStillGoStraightThrough() async {
        let outcome = await run { $0.receive("hey poke mach das licht an", isFinal: true) }
        XCTAssertEqual(outcome.delivered.count, 1)
        XCTAssertTrue(outcome.asked.isEmpty)
    }
}
