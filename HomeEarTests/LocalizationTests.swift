import XCTest
@testable import HomeEar

/// The app is shipped in English and German. These check that the compiled German
/// resources are really in the bundle, not that every sentence reads well.
final class LocalizationTests: XCTestCase {
    private func german() throws -> Bundle {
        let app = Bundle(for: UtteranceRouter.self)
        let path = try XCTUnwrap(app.path(forResource: "de", ofType: "lproj"), "de.lproj is missing from the app bundle")
        return try XCTUnwrap(Bundle(path: path))
    }

    func testInterfaceTextsAreTranslated() throws {
        let bundle = try german()
        XCTAssertEqual(bundle.localizedString(forKey: "Quit", value: nil, table: nil), "Beenden")
        XCTAssertEqual(bundle.localizedString(forKey: "Send anyway", value: nil, table: nil), "Trotzdem senden")
        XCTAssertEqual(bundle.localizedString(forKey: "Request Filter", value: nil, table: nil), "Anfragefilter")
    }

    func testStatusMessagesAreTranslated() throws {
        let bundle = try german()
        XCTAssertEqual(bundle.localizedString(forKey: "Listening on device", value: nil, table: nil), "Hört auf dem Gerät zu")
        let format = bundle.localizedString(forKey: "Home Assistant returned HTTP %lld; request not retried.", value: nil, table: nil)
        XCTAssertEqual(String(format: format, 503), "Home Assistant antwortete mit HTTP 503; Anfrage nicht wiederholt.")
    }

    func testPermissionPromptsAreTranslated() throws {
        let bundle = try german()
        let text = bundle.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist")
        XCTAssertTrue(text.contains("Mikrofon"), text)
    }

    func testEnglishStaysTheSource() {
        XCTAssertEqual(FilterSource.followUp.title.isEmpty, false)
        XCTAssertEqual(ActivityOutcome.sent.label.isEmpty, false)
    }
}
