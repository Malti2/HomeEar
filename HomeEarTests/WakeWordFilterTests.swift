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

/// Labelled sentences for tuning the filter: every change to scoring or
/// lexicons should keep this list green, and new misfires go in here first.
final class FilterCorpusTests: XCTestCase {
    private static let commands = [
        "mach das licht im wohnzimmer an",
        "schalte bitte die heizung im bad aus",
        "kannst du das licht in der küche ausmachen",
        "dimm das licht im schlafzimmer auf dreißig prozent",
        "stell einen timer auf zehn minuten",
        "mach die musik leiser",
        "spiel bitte etwas musik im wohnzimmer",
        "mach den fernseher aus",
        "das licht im flur bitte ausschalten",
        "licht im bad an bitte",
        "könntest du die rollläden runterfahren",
        "mach das licht bitte an",
        "erinner mich um acht an den termin",
        "stell die heizung auf zwanzig grad",
        "wecker auf sieben uhr stellen",
        "schalt das licht an",
        "mach mal das licht im flur aus",
        "bitte schalte das licht aus",
        "das licht im flur an machen",
        "kannst du die lampe im bad aus machen",
        "mach die wohnzimmerlampe heller",
        "mach das licht dunkler",
        "die musik leiser machen",
        "öffne das garagentor",
        "turn off the kitchen lights",
        "please set the thermostat to twenty degrees",
        "can you open the garage door",
        "set a timer for ten minutes",
        "play some music in the living room",
        "lock the front door",
        "could you dim the lights a bit",
        "switch the tv off",
        "turn the volume down"
    ]

    private static let questions = [
        "wie wird das wetter morgen",
        "wie spät ist es",
        "was ist die temperatur im wohnzimmer",
        "what's the weather tomorrow",
        "is there a meeting on my calendar today",
        "wann ist mein nächster termin",
        "when is my next appointment"
    ]

    private static let chatter = [
        "was hast du heute so gemacht",
        "ich glaube wir müssen morgen früh los",
        "er hat gestern das licht angelassen",
        "schatz kannst du bitte das licht anmachen",
        "mama mach das licht aus",
        "kannst du das licht anmachen papa",
        "wenn du das licht anmachst wird es heller",
        "ich finde dass das licht zu hell ist",
        "der fernseher läuft schon den ganzen tag",
        "die musik gestern war richtig laut",
        "ich habe das licht angemacht",
        "hat jemand das licht ausgemacht",
        "wir haben gestern über das wetter geredet",
        "ich dachte du wolltest das licht ausmachen",
        "und dann hat er das licht ausgemacht und ist gegangen",
        "heute abend gibt es regen und sonne im wechsel",
        "natürlich habe ich das gestern gesagt",
        "ich hatte einen komischen traum gestern",
        "weil das licht kaputt war konnte ich nichts sehen",
        "hast du das licht gestern ausgemacht",
        "he turned the lights off yesterday",
        "the music was too loud last night",
        "i think we should open the window",
        "because the lights were on all night",
        "did you turn the lights off yesterday",
        "she said the weather was really nice"
    ]

    func testCommandsAreAcceptedInStrictMode() {
        for text in Self.commands {
            guard case .accept = RequestFilter.checkProactive(text, strict: true) else {
                XCTFail("expected accept (strict): \(text)"); continue
            }
        }
    }

    func testQuestionsAreAcceptedInRelaxedMode() {
        for text in Self.questions {
            guard case .accept = RequestFilter.checkProactive(text, strict: false) else {
                XCTFail("expected accept (relaxed): \(text)"); continue
            }
        }
    }

    func testChatterIsRejectedEvenInRelaxedMode() {
        for text in Self.chatter {
            guard case .reject = RequestFilter.checkProactive(text, strict: false) else {
                XCTFail("expected reject (relaxed): \(text)"); continue
            }
        }
    }

    func testHouseholdNamesMarkRequestsAsAddressedToSomeoneElse() {
        let text = "anna kannst du das licht anmachen"
        guard case .accept = RequestFilter.checkProactive(text, strict: true) else {
            return XCTFail("should accept without the name configured")
        }
        guard case .reject = RequestFilter.checkProactive(text, strict: true, addressees: ["anna"]) else {
            return XCTFail("should reject when anna is a household name")
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
