import XCTest
@testable import HomeEar

final class AudioTests: XCTestCase {
    /// Feeds `seconds` of constant level at ~47 buffers per second.
    private func feed(_ tracker: AudioLevelTracker, db: Float, from start: TimeInterval, seconds: Double) -> TimeInterval {
        var time = start
        let end = start + seconds
        while time < end {
            tracker.record(db: db, at: time)
            time += 0.021
        }
        return time
    }

    func testSpeechAboveRoomNoiseHasPositiveSNR() {
        let tracker = AudioLevelTracker()
        var time = feed(tracker, db: -60, from: 0, seconds: 5)
        time = feed(tracker, db: -30, from: time, seconds: 1.5)
        let features = tracker.snapshot(at: time)
        XCTAssertNotNil(features)
        XCTAssertEqual(features?.snr ?? 0, 30, accuracy: 3)
    }

    func testQuietSpeechHasSmallSNR() {
        let tracker = AudioLevelTracker()
        var time = feed(tracker, db: -60, from: 0, seconds: 5)
        time = feed(tracker, db: -52, from: time, seconds: 1.5)
        XCTAssertEqual(tracker.snapshot(at: time)?.snr ?? 0, 8, accuracy: 3)
    }

    func testNoSnapshotWithoutEnoughSamples() {
        let tracker = AudioLevelTracker()
        XCTAssertNil(tracker.snapshot(at: 1))
        tracker.record(db: -40, at: 0.5)
        XCTAssertNil(tracker.snapshot(at: 1))
    }

    func testOldSamplesFallOutOfTheWindow() {
        let tracker = AudioLevelTracker(window: 3)
        let time = feed(tracker, db: -40, from: 0, seconds: 2)
        XCTAssertNil(tracker.snapshot(at: time + 10))
    }

    func testResetClearsState() {
        let tracker = AudioLevelTracker()
        let time = feed(tracker, db: -40, from: 0, seconds: 2)
        tracker.reset()
        XCTAssertNil(tracker.snapshot(at: time))
    }

    func testDecibels() {
        let full = [Float](repeating: 1, count: 256)
        let half = [Float](repeating: 0.1, count: 256)
        XCTAssertEqual(full.withUnsafeBufferPointer { AudioLevelTracker.decibels(of: $0) } ?? 99, 0, accuracy: 0.01)
        XCTAssertEqual(half.withUnsafeBufferPointer { AudioLevelTracker.decibels(of: $0) } ?? 99, -20, accuracy: 0.01)
        XCTAssertNil([Float]().withUnsafeBufferPointer { AudioLevelTracker.decibels(of: $0) })
    }

    func testPriorMarksOnlyClearlyQuietSpeechAsFar() {
        let profile = VoiceProfile()
        XCTAssertEqual(profile.cue(forSNR: 25), .normal)
        XCTAssertEqual(profile.cue(forSNR: 14), .normal)
        XCTAssertEqual(profile.cue(forSNR: 8), .far)
    }

    func testLearnedReferenceShiftsTheJudgement() {
        var profile = VoiceProfile()
        for _ in 0..<30 { profile.learn(snr: 40) }
        XCTAssertEqual(profile.cue(forSNR: 25), .far)
        XCTAssertEqual(profile.cue(forSNR: 35), .normal)
    }

    func testLearningIgnoresNonsense() {
        var profile = VoiceProfile()
        profile.learn(snr: -3)
        XCTAssertNil(profile.referenceSNR)
    }

    func testFarCueLowersProactiveScore() {
        let text = "mach das licht im flur an"
        guard case .accept = RequestFilter.checkProactive(text, strict: true) else { return XCTFail("baseline") }
        guard case .reject = RequestFilter.checkProactive(text, strict: true, audio: .far) else {
            return XCTFail("far speech should be rejected in strict mode")
        }
    }

    func testClearCommandSurvivesFarCueInRelaxedMode() {
        // verb 2 + entity 2 + polite 2 = 6; far costs 2, relaxed threshold is 3.
        guard case .accept = RequestFilter.checkProactive("bitte mach das licht im flur an", strict: false, audio: .far) else {
            return XCTFail("strong command should still pass")
        }
    }
}

final class AudioRouterTests: XCTestCase {
    func testFarSpeechIsFilteredButWakeWordIsNot() async {
        let (proactive, wake) = await MainActor.run { () -> ([String], [String]) in
            let router = UtteranceRouter()
            var delivered: [(String, FilterSource)] = []
            router.onDeliver = { delivered.append(($0, $1)) }
            router.receive("mach das licht im flur an", isFinal: true, audio: AudioFeatures(snr: 5))
            let proactive = delivered.map { $0.0 }
            router.receive("hey poke mach das licht im bad an", isFinal: true, audio: AudioFeatures(snr: 5))
            return (proactive, delivered.filter { $0.1 == .wakeWord }.map { $0.0 })
        }
        XCTAssertTrue(proactive.isEmpty)
        XCTAssertEqual(wake, ["mach das licht im bad an"])
    }

    func testWakeWordCommandTeachesTheReferenceLevel() async {
        let reference = await MainActor.run { () -> Double? in
            let router = UtteranceRouter()
            var reported: Double?
            router.onVoiceReferenceChanged = { reported = $0 }
            router.receive("hey poke mach das licht im bad an", isFinal: true, audio: AudioFeatures(snr: 30))
            return reported
        }
        XCTAssertEqual(reference ?? 0, 30, accuracy: 0.001)
    }

    func testAudioCuesCanBeDisabled() async {
        let count = await MainActor.run { () -> Int in
            let router = UtteranceRouter()
            router.config.audioCuesEnabled = false
            var delivered = 0
            router.onDeliver = { _, _ in delivered += 1 }
            router.receive("mach das licht im flur an", isFinal: true, audio: AudioFeatures(snr: 5))
            return delivered
        }
        XCTAssertEqual(count, 1)
    }
}
