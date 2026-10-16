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

    func testAcceptsInfinitiveCommands() {
        assertAccept("das licht im flur anmachen", strict: true)
        assertAccept("die heizung im bad bitte ausschalten", strict: true)
    }

    func testPunctuationDoesNotHideEntities() {
        assertAccept("mach bitte das licht, schnell", strict: true)
    }

    func testShortEntitiesDoNotMatchInsideWords() {
        // "natürlich" contains "tür", "traum" contains "raum", "fuhr" contains "uhr".
        assertReject("natürlich habe ich das gestern gesagt", strict: false)
        assertReject("ich hatte einen komischen traum gestern", strict: false)
        assertReject("wir fuhr gestern nach hause zurück", strict: false)
    }

    func testCompoundEntitiesMatchByTail() {
        assertAccept("mach die wohnzimmerlampe an", strict: true)
        assertAccept("schalte die stehlampe im flur aus", strict: true)
    }

    func testNarrativeSubjectIsPenalised() {
        assertReject("er will dass ich das licht anmachen", strict: true)
        assertReject("ich habe gestern das licht anmachen müssen", strict: true)
    }

    func testPoliteFirstPersonStillAccepted() {
        assertAccept("ich möchte das licht heller haben", strict: true)
    }

    func testCustomKeywords() {
        XCTAssertEqual(RequestFilter.parseKeywords("Ventilator, Kamin  garage;x"), ["ventilator", "kamin", "garage"])
        let text = "mach den pizzaofen an"
        guard case .reject = RequestFilter.checkProactive(text, strict: true) else {
            return XCTFail("should reject without keyword")
        }
        guard case .accept = RequestFilter.checkProactive(text, strict: true, extra: ["pizzaofen"]) else {
            return XCTFail("should accept with keyword")
        }
    }
}

final class QuietHoursTests: XCTestCase {
    private func date(hour: Int) -> (Date, Calendar) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: hour, minute: 30))!
        return (date, calendar)
    }

    func testWrapsPastMidnight() {
        let quiet = QuietHours(startHour: 23, endHour: 7)
        for hour in [23, 0, 3, 6] { let (d, c) = date(hour: hour); XCTAssertTrue(quiet.contains(d, calendar: c), "\(hour)") }
        for hour in [7, 12, 22] { let (d, c) = date(hour: hour); XCTAssertFalse(quiet.contains(d, calendar: c), "\(hour)") }
    }

    func testSameDayWindow() {
        let quiet = QuietHours(startHour: 13, endHour: 15)
        let (inside, c1) = date(hour: 14), (outside, c2) = date(hour: 15)
        XCTAssertTrue(quiet.contains(inside, calendar: c1))
        XCTAssertFalse(quiet.contains(outside, calendar: c2))
    }

    func testEqualBoundsMeanNoWindow() {
        let (d, c) = date(hour: 3)
        XCTAssertFalse(QuietHours(startHour: 5, endHour: 5).contains(d, calendar: c))
    }
}
