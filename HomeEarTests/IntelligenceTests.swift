import XCTest
@testable import HomeEar

/// Scores 3: one point short of strict mode, with an entity and a question opener.
private let borderlineSentence = "wie wird das wetter morgen"

private final class Counter: @unchecked Sendable {
    var value = 0
}

/// Lets the router's background task finish. File-level so the @MainActor tests don't
/// send the (non-Sendable) test case across an isolation boundary.
private func settle() async throws {
    try await Task.sleep(nanoseconds: 250_000_000)
}

/// The language model itself can't run in CI, so the router is driven with stand-in judges.
final class IntelligenceTests: XCTestCase {
    @MainActor func testYesDeliversWithItsOwnSource() async throws {
        let router = UtteranceRouter()
        router.config.useLanguageModel = true
        router.judge = { _ in true }
        var delivered: [(String, FilterSource)] = []
        var asked = 0
        router.onDeliver = { delivered.append(($0, $1)) }
        router.onAskBack = { _ in asked += 1 }
        router.receive(borderlineSentence, isFinal: true)
        try await settle()
        XCTAssertEqual(delivered.map { $0.0 }, [borderlineSentence])
        XCTAssertEqual(delivered.first?.1, .intelligence)
        XCTAssertEqual(asked, 0)
    }

    @MainActor func testNoDropsTheSentenceAndSaysWhy() async throws {
        let router = UtteranceRouter()
        router.config.useLanguageModel = true
        router.judge = { _ in false }
        var delivered = 0
        var events: [ActivityEntry] = []
        router.onDeliver = { _, _ in delivered += 1 }
        router.onEvent = { events.append($0) }
        router.receive(borderlineSentence, isFinal: true)
        try await settle()
        XCTAssertEqual(delivered, 0)
        XCTAssertTrue(events.contains { $0.outcome == .filtered && $0.reason.contains("Apple Intelligence") })
    }

    @MainActor func testNoAnswerFallsBackToAskingTheUser() async throws {
        let router = UtteranceRouter()
        router.config.useLanguageModel = true
        router.judge = { _ in nil }
        var delivered = 0
        var asked: [PendingRequest] = []
        router.onDeliver = { _, _ in delivered += 1 }
        router.onAskBack = { asked.append($0) }
        router.receive(borderlineSentence, isFinal: true)
        try await settle()
        XCTAssertEqual(delivered, 0)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked.first?.reason.contains("no answer") ?? false)
    }

    @MainActor func testSlowAnswerTimesOutAndAsks() async throws {
        let router = UtteranceRouter()
        router.config.useLanguageModel = true
        router.config.judgeTimeout = 0.05
        router.judge = { _ in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return true
        }
        var delivered = 0
        var asked = 0
        router.onDeliver = { _, _ in delivered += 1 }
        router.onAskBack = { _ in asked += 1 }
        router.receive(borderlineSentence, isFinal: true)
        try await settle()
        XCTAssertEqual(delivered, 0, "a late yes must not be sent")
        XCTAssertEqual(asked, 1)
    }

    @MainActor func testSwitchedOffNeverAsksTheModel() async throws {
        let router = UtteranceRouter()
        let calls = Counter()
        router.config.useLanguageModel = false
        router.judge = { _ in calls.value += 1; return true }
        var asked = 0
        router.onAskBack = { _ in asked += 1 }
        router.receive(borderlineSentence, isFinal: true)
        try await settle()
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(asked, 1)
    }

    @MainActor func testDistantSpeechIsNotJudged() async throws {
        let router = UtteranceRouter()
        let calls = Counter()
        router.config.useLanguageModel = true
        router.judge = { _ in calls.value += 1; return true }
        var delivered = 0
        router.onDeliver = { _, _ in delivered += 1 }
        router.receive(borderlineSentence, isFinal: true, audio: AudioFeatures(snr: 5))
        try await settle()
        XCTAssertEqual(calls.value, 0)
        XCTAssertEqual(delivered, 0)
    }

    @MainActor func testSameSentenceIsNotJudgedTwiceAtOnce() async throws {
        let router = UtteranceRouter()
        let calls = Counter()
        router.config.useLanguageModel = true
        router.judge = { _ in
            calls.value += 1
            try? await Task.sleep(nanoseconds: 100_000_000)
            return false
        }
        router.receive(borderlineSentence, isFinal: true)
        router.receive(borderlineSentence, isFinal: true)
        try await settle()
        XCTAssertEqual(calls.value, 1)
    }

    @MainActor func testAnswerAfterStoppingTheMicrophoneIsIgnored() async throws {
        let router = UtteranceRouter()
        router.config.useLanguageModel = true
        router.judge = { _ in
            try? await Task.sleep(nanoseconds: 80_000_000)
            return true
        }
        var delivered = 0
        router.onDeliver = { _, _ in delivered += 1 }
        router.receive(borderlineSentence, isFinal: true)
        router.reset()
        try await settle()
        XCTAssertEqual(delivered, 0)
    }

    func testAvailabilityCheckNeverCrashes() {
        // On a runner without Apple Intelligence this reports a reason; either way it answers.
        let availability = AppleIntelligence.availability()
        XCTAssertFalse(availability.message.isEmpty)
    }
}
