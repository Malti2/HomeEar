import XCTest
@testable import HomeEar

/// Scores 3: one point short of strict mode, with an entity and a question opener.
/// File-level so the @MainActor test closures don't capture the test case.
private let borderline = "wie wird das wetter morgen"

/// Router behaviour around questions, confirmations and follow-ups.
final class ConversationTests: XCTestCase {
    private struct Outcome {
        var delivered: [(text: String, source: FilterSource)] = []
        var asked: [String] = []
        var pending: [String?] = []
    }

    private func run(_ body: @MainActor (UtteranceRouter) -> Void) async -> Outcome {
        await MainActor.run {
            let router = UtteranceRouter()
            var outcome = Outcome()
            router.onDeliver = { outcome.delivered.append(($0, $1)) }
            router.onAskBack = { outcome.asked.append($0.text) }
            router.onPendingChanged = { outcome.pending.append($0?.text) }
            body(router)
            return outcome
        }
    }

    func testBorderlineRequestIsAskedNotSent() async {
        let outcome = await run { $0.receive(borderline, isFinal: true) }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertEqual(outcome.asked, [borderline])
        XCTAssertEqual(outcome.pending, [borderline])
    }

    func testYesSendsTheRequest() async {
        let outcome = await run {
            $0.receive(borderline, isFinal: true)
            $0.receive("ja", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, [borderline])
        XCTAssertEqual(outcome.delivered.first?.source, .proactive)
        XCTAssertEqual(outcome.pending, [borderline, nil])
    }

    func testNoDropsTheRequestAndLaterYesDoesNothing() async {
        let outcome = await run {
            $0.receive(borderline, isFinal: true)
            $0.receive("nein", isFinal: true)
            $0.receive("ja", isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testUnrelatedSpeechKeepsTheQuestionOpen() async {
        let outcome = await run {
            $0.receive(borderline, isFinal: true)
            $0.receive("hast du das gesehen", isFinal: true)
            $0.receive("ja", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, [borderline])
    }

    func testPanelButtons() async {
        let confirmed = await run {
            $0.receive(borderline, isFinal: true)
            $0.confirmPending()
        }
        XCTAssertEqual(confirmed.delivered.map { $0.text }, [borderline])
        let discarded = await run {
            $0.receive(borderline, isFinal: true)
            $0.discardPending()
            $0.confirmPending()
        }
        XCTAssertTrue(discarded.delivered.isEmpty)
    }

    func testDistantSpeechIsNotAskedAbout() async {
        let outcome = await run { $0.receive(borderline, isFinal: true, audio: AudioFeatures(snr: 5)) }
        XCTAssertTrue(outcome.asked.isEmpty)
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testAskingCanBeSwitchedOff() async {
        let outcome = await run {
            $0.config.askWhenUnsure = false
            $0.receive(borderline, isFinal: true)
        }
        XCTAssertTrue(outcome.asked.isEmpty)
    }

    func testSameSentenceIsNotAskedTwiceInARow() async {
        let outcome = await run {
            $0.receive(borderline, isFinal: true)
            $0.discardPending()
            $0.receive(borderline, isFinal: true)
        }
        XCTAssertEqual(outcome.asked.count, 1)
    }

    func testExpiredQuestionIsDropped() async {
        let outcome = await run {
            $0.config.confirmationWindow = -1
            $0.receive(borderline, isFinal: true)
            $0.receive("ja", isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
        XCTAssertEqual(outcome.pending, [borderline, nil])
    }

    // MARK: follow-ups

    func testAnswerIsAcceptedWithoutWakeWord() async {
        let outcome = await run {
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("im flur", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["im flur"])
        XCTAssertEqual(outcome.delivered.first?.source, .followUp)
    }

    func testContinuationAfterACommandNeedsToLookLikeOne() async {
        let accepted = await run {
            $0.openFollowUp(expectsAnswer: false)
            $0.receive("und im schlafzimmer auch", isFinal: true)
        }
        XCTAssertEqual(accepted.delivered.map { $0.text }, ["und im schlafzimmer auch"])
        let ignored = await run {
            $0.openFollowUp(expectsAnswer: false)
            $0.receive("ich glaube das war gestern", isFinal: true)
        }
        XCTAssertTrue(ignored.delivered.isEmpty)
    }

    func testPartialsDoNotTriggerFollowUps() async {
        let outcome = await run {
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("im flur", isFinal: false)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testFollowUpsCanBeSwitchedOff() async {
        let outcome = await run {
            $0.config.followUpEnabled = false
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("im flur", isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testCancelClosesTheFollowUpWindow() async {
        let outcome = await run {
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("abbrechen", isFinal: true)
            $0.receive("im flur", isFinal: true)
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testDistantSpeechDoesNotAnswer() async {
        let outcome = await run {
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("im flur", isFinal: true, audio: AudioFeatures(snr: 5))
        }
        XCTAssertTrue(outcome.delivered.isEmpty)
    }

    func testWakeWordStillWorksInsideTheWindow() async {
        let outcome = await run {
            $0.openFollowUp(expectsAnswer: true)
            $0.receive("hey poke mach das licht an", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, ["mach das licht an"])
        XCTAssertEqual(outcome.delivered.first?.source, .wakeWord)
    }

    func testFollowUpWindowDoesNotReplaceAnOpenQuestion() async {
        let outcome = await run {
            $0.receive(borderline, isFinal: true)
            $0.openFollowUp(expectsAnswer: false)
            $0.receive("ja", isFinal: true)
        }
        XCTAssertEqual(outcome.delivered.map { $0.text }, [borderline])
    }
}
