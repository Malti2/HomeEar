import XCTest
@testable import HomeEar

final class EchoGuardTests: XCTestCase {
    func testStartsOpen() {
        XCTAssertFalse(EchoGuard().shouldDrop(at: 100))
    }

    func testDropsWhileSpeaking() {
        var guardState = EchoGuard()
        guardState.began(at: 100)
        XCTAssertTrue(guardState.shouldDrop(at: 100))
        XCTAssertTrue(guardState.shouldDrop(at: 130), "long speech keeps the guard closed")
    }

    func testNeverMutesForeverIfTheSynthesizerStaysSilent() {
        var guardState = EchoGuard()
        guardState.began(at: 100)
        XCTAssertFalse(guardState.shouldDrop(at: 100 + EchoGuard.maxSpeaking + 1))
    }

    func testStaysClosedForTheTailThenReopens() {
        var guardState = EchoGuard()
        guardState.began(at: 49)
        guardState.ended(at: 50)
        XCTAssertTrue(guardState.shouldDrop(at: 50.5))
        XCTAssertTrue(guardState.shouldDrop(at: 50 + EchoGuard.tail - 0.01))
        XCTAssertFalse(guardState.shouldDrop(at: 50 + EchoGuard.tail + 0.01))
    }

    func testNewSpeechReclosesTheGuard() {
        var guardState = EchoGuard()
        guardState.began(at: 9)
        guardState.ended(at: 10)
        guardState.began(at: 19)
        XCTAssertTrue(guardState.shouldDrop(at: 20))
    }
}
