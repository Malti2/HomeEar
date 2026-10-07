import XCTest
@testable import HomeEar

final class HomeAssistantTests: XCTestCase {
    func testSecureURLAndPath() throws {
        let client = try HomeAssistantClient(server: "https://ha.example.test", token: "synthetic-test-token")
        let request = client.request(path: "api/conversation/process", method: "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://ha.example.test/api/conversation/process")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-test-token")
        XCTAssertEqual(request.httpMethod, "POST")
    }
    func testRejectsPublicPlainHTTP() {
        XCTAssertThrowsError(try HomeAssistantClient(server: "http://example.test:8123", token: "test"))
        XCTAssertThrowsError(try HomeAssistantClient(server: "http://203.0.113.1:8123", token: "test"))
    }
    func testRejectsMalformedPrivateHost() {
        for value in ["http://10..0.0.1:8123", "http://10.0.0.1.extra:8123", "http://10.0.0.256:8123"] {
            XCTAssertThrowsError(try HomeAssistantClient(server: value, token: "test"), value)
        }
    }
    func testAllowsPrivateNetworkHTTP() throws {
        _ = try HomeAssistantClient(server: "http://192.168.1.10:8123", token: "test")
        _ = try HomeAssistantClient(server: "http://10.0.0.10:8123", token: "test")
        _ = try HomeAssistantClient(server: "http://localhost:8123", token: "test")
    }
    func testRejectsCredentialsAndInvalidURL() {
        for value in ["ha.example.test", "https://user:password@ha.example.test", "https://ha.example.test?token=secret", "https://ha.example.test#fragment"] {
            XCTAssertThrowsError(try HomeAssistantClient(server: value, token: "test"), value)
        }
    }
    func testParsesActionResult() throws {
        let json = #"{"response":{"response_type":"action_done","data":{"success":[{"id":"light.test"}],"failed":[]},"speech":{"plain":{"speech":"Done"}}}}"#
        let result = try HomeAssistantClient.parseReply(Data(json.utf8))
        XCTAssertEqual(result.status, "Action completed")
        XCTAssertEqual(result.speech, "Done")
    }
    func testDoesNotTreatErrorAsSuccess() throws {
        let json = #"{"response":{"response_type":"error","data":{"code":"no_intent_match"}}}"#
        XCTAssertEqual(try HomeAssistantClient.parseReply(Data(json.utf8)).status, "Not completed: no_intent_match")
    }
    func testPartialFailureIsNotSuccess() throws {
        let json = #"{"response":{"response_type":"action_done","data":{"success":[{}],"failed":[{}]}}}"#
        XCTAssertEqual(try HomeAssistantClient.parseReply(Data(json.utf8)).status, "Some targets failed; check Home Assistant")
    }
    func testRejectsMalformedResponse() {
        XCTAssertThrowsError(try HomeAssistantClient.parseReply(Data(#"{"response":{}}"#.utf8)))
    }
}

final class UpdateDiscoveryTests: XCTestCase {
    let sample = Data(#"[{"draft":false,"prerelease":true,"tag_name":"v0.1.4","assets":[{"name":"appcast.xml","browser_download_url":"https://github.com/Malti2/HomeEar/releases/download/v0.1.4/appcast.xml"}]}]"#.utf8)
    func testStableChannelHasNoRelease() throws {
        XCTAssertNil(try ReleaseDiscovery.feed(from: sample, channel: .stable))
    }
    func testBetaChannelFindsPrerelease() throws {
        XCTAssertEqual(try ReleaseDiscovery.feed(from: sample, channel: .beta)?.lastPathComponent, "appcast.xml")
    }
    func testMissingFeedIsAnErrorNotEmptyChannel() {
        let data = Data(#"[{"draft":false,"prerelease":false,"tag_name":"v1","assets":[]}]"#.utf8)
        XCTAssertThrowsError(try ReleaseDiscovery.feed(from: data, channel: .stable))
    }
    func testUntrustedFeedIsRejected() {
        let data = Data(#"[{"draft":false,"prerelease":false,"tag_name":"v1","assets":[{"name":"appcast.xml","browser_download_url":"https://example.test/appcast.xml"}]}]"#.utf8)
        XCTAssertThrowsError(try ReleaseDiscovery.feed(from: data, channel: .stable))
    }
    func testDraftIsIgnored() throws {
        let data = Data(#"[{"draft":true,"prerelease":false,"tag_name":"v1","assets":[]}]"#.utf8)
        XCTAssertNil(try ReleaseDiscovery.feed(from: data, channel: .stable))
    }
}
