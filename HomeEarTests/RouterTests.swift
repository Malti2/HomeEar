import XCTest
@testable import HomeEar

final class RouterTests: XCTestCase {
    /// Drives a fresh router through (text, isFinal) inputs on the main actor
    /// and returns everything it delivered.
    private func driveRouter(_ inputs: [(String, Bool)],
                            wakeWordEnabled: Bool = true,
                            proactiveEnabled: Bool = true) async -> [(String, FilterSource)] {
        await MainActor.run {
            let router = UtteranceRouter()
            router.config.wakeWordEnabled = wakeWordEnabled
            router.config.proactiveEnabled = proactiveEnabled
            var delivered: [(String, FilterSource)] = []
            router.onDeliver = { delivered.append(($0, $1)) }
            for (text, isFinal) in inputs {
                router.receive(text, isFinal: isFinal)
            }
            return delivered
        }
    }

    func testWakeWordDeliversCommandFromFinal() async {
        let delivered = await driveRouter([
            ("hey poke", false),
            ("hey poke mach das licht an", true),
        ])
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].0, "mach das licht an")
        XCTAssertEqual(delivered[0].1, .wakeWord)
    }

    func testLoneWakeWordCapturesNextUtterance() async {
        let delivered = await driveRouter([
            ("hey poke", true),
            ("mach das licht an", true),
        ])
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].0, "mach das licht an")
        XCTAssertEqual(delivered[0].1, .wakeWord)
    }

    func testPartialAloneDeliversNothing() async {
        let delivered = await driveRouter([("mach das licht", false)])
        XCTAssertTrue(delivered.isEmpty)
    }

    func testDuplicateIsSuppressed() async {
        let delivered = await driveRouter([
            ("mach das licht an", true),
            ("mach das licht an", true),
        ])
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].1, .proactive)
    }

    func testProactiveRejectsChatter() async {
        let delivered = await driveRouter([("was hast du heute so gemacht", true)])
        XCTAssertTrue(delivered.isEmpty)
    }

    func testWakeWordDisabledFallsBackToProactive() async {
        let delivered = await driveRouter(
            [("hey poke mach das licht an", true)],
            wakeWordEnabled: false
        )
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].0, "mach das licht an")
        XCTAssertEqual(delivered[0].1, .proactive)
    }

    func testProactiveDisabledDeliversNothing() async {
        let delivered = await driveRouter(
            [("mach das licht an", true)],
            proactiveEnabled: false
        )
        XCTAssertTrue(delivered.isEmpty)
    }
}
