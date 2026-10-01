import XCTest
@testable import HomeEar

final class WakeWordTests: XCTestCase {
    func testDetectsPlainWakeWord() {
        let match = WakeWordDetector.detect(in: "Hey Poke, mach das Licht an")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.commandText, "mach das Licht an")
    }

    func testDetectsFuzzyVariants() {
        for text in ["hey poak mach das licht an", "hey pouk dimm das licht", "ey poke, wie wird das wetter"] {
            XCTAssertNotNil(WakeWordDetector.detect(in: text), text)
        }
    }

    func testLoneWakeWordHasEmptyCommand() {
        let match = WakeWordDetector.detect(in: "Hey Poke")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.commandText, "")
    }

    func testBareLeadingPokeStillWorks() {
        let match = WakeWordDetector.detect(in: "poke mach das licht an")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.commandText, "mach das licht an")
    }

    func testAllowsOneFillerWord() {
        let match = WakeWordDetector.detect(in: "hey, äh, poke, licht an")
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.commandText, "licht an")
    }

    func testNoFalsePositives() {
        XCTAssertNil(WakeWordDetector.detect(in: "hey peter mach das licht an"))
        XCTAssertNil(WakeWordDetector.detect(in: "hey bob, komm her"))
        XCTAssertNil(WakeWordDetector.detect(in: "ich habe mit poke telefoniert"))
        XCTAssertNil(WakeWordDetector.detect(in: "mach das licht an"))
    }

    func testStripLeadingWakeWord() {
        XCTAssertEqual(WakeWordDetector.stripLeadingWakeWord(from: "Hey Poke, mach das Licht an"), "mach das Licht an")
        XCTAssertNil(WakeWordDetector.stripLeadingWakeWord(from: "sag hey poke mal bescheid"))
    }
}

final class FilterTests: XCTestCase {
    private func assertAccept(_ text: String, strict: Bool, file: StaticString = #file, line: UInt = #line) {
        let decision = RequestFilter.checkProactive(text, strict: strict)
        guard case .accept(let source, _) = decision else {
            XCTFail("expected accept for \(text)", file: file, line: line)
            return
        }
        XCTAssertEqual(source, .proactive)
    }

    private func assertReject(_ text: String, strict: Bool, file: StaticString = #file, line: UInt = #line) {
        let decision = RequestFilter.checkProactive(text, strict: strict)
        guard case .reject = decision else {
            XCTFail("expected reject for \(text)", file: file, line: line)
            return
        }
    }

    func testAcceptsImperativeCommands() {
        assertAccept("mach das licht im wohnzimmer an", strict: true)
        assertAccept("schalte die heizung im bad ein", strict: true)
        assertAccept("stell den wecker auf sieben uhr", strict: true)
        assertAccept("turn on the living room lights", strict: true)
        assertAccept("dim the lights to fifty percent", strict: true)
    }

    func testAcceptsPoliteFramings() {
        assertAccept("kannst du das licht im flur anmachen", strict: true)
        assertAccept("bitte mach das licht an", strict: true)
    }

    func testRejectsChatter() {
        assertReject("was hast du heute so gemacht", strict: true)
        assertReject("und dann hat er gesagt dass er nicht kommt", strict: true)
        assertReject("haha das war lustig vorhin", strict: true)
    }

    func testRejectsThirdPerson() {
        // "er macht das Licht an" talks *about* someone — "macht" is not the imperative "mach".
        assertReject("er macht das licht an", strict: true)
    }

    func testRejectsTooShort() {
        assertReject("danke", strict: true)
        assertReject("ja", strict: false)
    }

    func testQuestionNeedsRelaxedMode() {
        assertReject("wie wird das wetter morgen", strict: true)
        assertAccept("wie wird das wetter morgen", strict: false)
    }

    func testStripsWakeWordBeforeScoring() {
        assertAccept("hey poke mach das licht an", strict: true)
    }
}
