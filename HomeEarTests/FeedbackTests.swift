import XCTest
@testable import HomeEar

final class FeedbackTests: XCTestCase {
    func testSteadyStates() {
        XCTAssertEqual(AssistantPhase.resolve(microphoneOn: false, capturing: false, flash: nil), .paused)
        XCTAssertEqual(AssistantPhase.resolve(microphoneOn: true, capturing: false, flash: nil), .listening)
        XCTAssertEqual(AssistantPhase.resolve(microphoneOn: true, capturing: true, flash: nil), .capturing)
    }

    func testFlashWinsOverEverything() {
        XCTAssertEqual(AssistantPhase.resolve(microphoneOn: true, capturing: true, flash: .sent), .sent)
        XCTAssertEqual(AssistantPhase.resolve(microphoneOn: false, capturing: false, flash: .error), .error)
    }

    func testEveryPhaseHasItsOwnSymbol() {
        let phases: [AssistantPhase] = [.paused, .listening, .capturing, .sent, .error]
        XCTAssertEqual(Set(phases.map(\.symbol)).count, phases.count)
        XCTAssertEqual(AssistantPhase.listening.symbol, "waveform")
        XCTAssertEqual(AssistantPhase.paused.symbol, "waveform.slash")
    }

    func testSoundCuesUseDistinctSystemSounds() {
        let names = [SoundCue.heard, .sent, .error].map(\.systemSoundName)
        XCTAssertEqual(Set(names).count, 3)
    }
}
