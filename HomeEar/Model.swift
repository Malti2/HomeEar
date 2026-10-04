import Foundation
import Security
import ServiceManagement
import Combine

protocol AgentBackend: Sendable {
    func send(_ text: String) async throws
}

struct PokeBackend: AgentBackend {
    enum Failure: Error { case missingKey, rejected(Int), invalidResponse }
    func send(_ text: String) async throws {
        guard let key = KeyStore.load(), !key.isEmpty else { throw Failure.missingKey }
        var request = URLRequest(url: URL(string: "https://poke.com/api/v1/inbound/api-message")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": text])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw Failure.rejected(http.statusCode) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard object?["success"] as? Bool == true else { throw Failure.invalidResponse }
    }
}

enum KeyStore {
    static let service = "net.homeear.poke-api"
    static func save(_ value: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "v2"]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "v2",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

@MainActor final class AppState: ObservableObject {
    @Published var microphoneOn = false
    @Published var speechState = "Not started"
    @Published var apiState = "Add a Poke key"
    @Published var ttsState = "Not connected"
    @Published var latestText = "Nothing heard yet"
    @Published var latestDecision = ""
    @Published var completedSetup = UserDefaults.standard.bool(forKey: "setupComplete")
    @Published var language = UserDefaults.standard.string(forKey: "language") ?? "de-DE"
    @Published var startAtLogin = false
    @Published var voiceID = UserDefaults.standard.string(forKey: "voiceID") ?? ""
    @Published var strictFilter = UserDefaults.standard.object(forKey: "strictFilter") as? Bool ?? true {
        didSet { UserDefaults.standard.set(strictFilter, forKey: "strictFilter") }
    }
    @Published var wakeWordEnabled = UserDefaults.standard.object(forKey: "wakeWordEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(wakeWordEnabled, forKey: "wakeWordEnabled") }
    }
    @Published var proactiveEnabled = UserDefaults.standard.object(forKey: "proactiveEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(proactiveEnabled, forKey: "proactiveEnabled") }
    }
    let router = UtteranceRouter()
    @Published var selectedBackend = UserDefaults.standard.string(forKey: "backend") ?? "poke" {
        didSet { UserDefaults.standard.set(selectedBackend, forKey: "backend") }
    }
    @Published var haURL = UserDefaults.standard.string(forKey: "haURL") ?? "" {
        didSet { UserDefaults.standard.set(haURL, forKey: "haURL") }
    }
    @Published var haState = "Not configured"
    @Published var haResponse = ""
    @Published var haTesting = false
    private var haRequestInFlight = false
    lazy var speech = AppleSpeechEngine(state: self)
    lazy var tts = VoiceOutput(state: self)
    lazy var mcp = MCPServer(state: self)
    let tunnel = TunnelManager()
    let updates = UpdateChecker()

    init() {
        router.onDeliver = { [weak self] text, source in self?.forwardRequest(text: text, source: source) }
        router.onDecision = { [weak self] decision in self?.latestDecision = decision }
        router.onCommandModeChanged = { [weak self] active in
            guard let self else { return }
            self.speechState = active ? "Listening for command…" : (self.microphoneOn ? "Listening on device" : "Paused")
        }
        Task { @MainActor in
            do { try mcp.start(); if completedSetup && selectedBackend == "poke" { tunnel.start() } }
            catch { ttsState = "Local tool unavailable: \(error.localizedDescription)" }
        }
    }
    func start() {
        guard !microphoneOn else { return }
        Task {
            do {
                try await speech.start(language: language)
                microphoneOn = true
                speechState = "Listening on device"
            } catch {
                microphoneOn = false
                speechState = "Speech unavailable: \(error.localizedDescription)"
            }
        }
    }
    func stop() {
        speech.stop()
        router.reset()
        microphoneOn = false
        speechState = "Paused"
    }
    func receive(_ text: String, isFinal: Bool) {
        latestText = text
        router.config.wakeWordEnabled = wakeWordEnabled
        router.config.proactiveEnabled = proactiveEnabled
        router.config.strictFilter = strictFilter
        router.receive(text, isFinal: isFinal)
    }
    private func forwardRequest(text: String, source: FilterSource) {
        // Capture the selected destination before suspension: one request, one backend.
        let destination = selectedBackend
        guard completedSetup || destination == "home_assistant" else { return }
        if destination == "home_assistant" {
            guard !haRequestInFlight else {
                latestDecision = "Request not sent: Home Assistant is still processing the previous request"
                return
            }
            let server = haURL
            guard let token = HATokenStore.load(), !token.isEmpty else {
                haState = "Save a Home Assistant token in Settings"
                latestDecision = "Request not sent: Home Assistant is not configured"
                return
            }
            let locale = language.hasPrefix("de") ? "de" : "en"
            haRequestInFlight = true
            latestDecision = "\(source.rawValue) → sending to Home Assistant"
            Task {
                defer { haRequestInFlight = false }
                do {
                    let client = try HomeAssistantClient(server: server, token: token)
                    let response = try await client.process(text, language: locale)
                    haResponse = response.speech
                    haState = response.status
                    latestDecision = "Home Assistant: \(response.status)"
                } catch {
                    // Never retry a command after a timeout: it might have executed.
                    haState = error.localizedDescription
                    latestDecision = "Home Assistant: result unconfirmed; no retry"
                }
            }
        } else {
            latestDecision = "\(source.rawValue) → sending to Poke"
            Task {
                do {
                    try await PokeBackend().send(text)
                    apiState = "Delivered to Poke"
                    latestDecision = "\(source.rawValue) → sent to Poke"
                } catch { apiState = "Forwarding unavailable: \(error.localizedDescription)" }
            }
        }
    }
    func saveHAToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let saved = HATokenStore.save(trimmed)
        haState = saved ? "Token saved; test the connection" : "Could not save token in Keychain"
        return saved
    }
    func testHomeAssistant() {
        guard !haTesting else { return }
        let server = haURL
        guard let token = HATokenStore.load(), !token.isEmpty else {
            haState = "Save a token first"
            return
        }
        haTesting = true
        haState = "Checking connection..."
        Task {
            defer { haTesting = false }
            do {
                let client = try HomeAssistantClient(server: server, token: token)
                try await client.testConnection()
                haState = "Connected; API authenticated"
            } catch { haState = error.localizedDescription }
        }
    }
    func speakHAResponse() {
        guard !haResponse.isEmpty else { return }
        // Pause before local TTS so the response cannot trigger the microphone.
        stop()
        tts.speak(haResponse)
        latestDecision = "Reading Home Assistant reply; microphone paused"
    }
    func saveLanguage(_ value: String) {
        language = value
        UserDefaults.standard.set(value, forKey: "language")
        if microphoneOn { stop(); start() }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            startAtLogin = enabled
        } catch { latestDecision = "Login item error: \(error.localizedDescription)" }
    }
}


/// Home Assistant credentials are independent of the Poke key.
enum HATokenStore {
    private static let service = "net.homeear.home-assistant"
    static func save(_ value: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }
    static func load() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "token",
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct HAReply: Sendable {
    let status: String
    let speech: String
}

/// Refuse redirects so an authenticated request never migrates to another host.
private final class HANoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct HomeAssistantClient: Sendable {
    enum Failure: LocalizedError {
        case invalidURL, insecureURL, authorization, status(Int), malformed, resultUnconfirmed
        var errorDescription: String? {
            switch self {
            case .invalidURL: "Enter a Home Assistant URL without credentials, query, or fragment."
            case .insecureURL: "Use HTTPS for remote Home Assistant. HTTP is allowed only for localhost or a private IPv4 address."
            case .authorization: "Home Assistant rejected the token."
            case .status(let code): "Home Assistant returned HTTP \(code); request not retried."
            case .malformed: "Home Assistant returned an unexpected response."
            case .resultUnconfirmed: "Connection failed or timed out. The action may have run; check Home Assistant before repeating."
            }
        }
    }
    let base: URL
    private let token: String
    init(server: String, token: String) throws {
        guard let url = URL(string: server.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { throw Failure.invalidURL }
        if scheme == "http" && !Self.isPrivateHost(host.lowercased()) { throw Failure.insecureURL }
        base = url
        self.token = token
    }
    private static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return false }
        let parts = octets.compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168)
            || (parts[0] == 172 && (16...31).contains(parts[1]))
    }
    func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 12
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return request
    }
    private func perform(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: HANoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.resultUnconfirmed }
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        if http.statusCode == 401 || http.statusCode == 403 { throw Failure.authorization }
        guard (200..<300).contains(http.statusCode) else { throw Failure.status(http.statusCode) }
        return data
    }
    func testConnection() async throws {
        let data = try await perform(request(path: "api/"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["message"] as? String == "API running." else { throw Failure.malformed }
    }
    func process(_ text: String, language: String) async throws -> HAReply {
        let body = try JSONSerialization.data(withJSONObject: ["text": text, "language": language,
                                                                "agent_id": "home_assistant"])
        let data = try await perform(request(path: "api/conversation/process", method: "POST", body: body))
        return try Self.parseReply(data)
    }
    static func parseReply(_ data: Data) throws -> HAReply {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = object["response"] as? [String: Any],
              let type = response["response_type"] as? String else { throw Failure.malformed }
        let speech = ((response["speech"] as? [String: Any])?["plain"] as? [String: Any])?["speech"] as? String ?? ""
        let details = response["data"] as? [String: Any] ?? [:]
        switch type {
        case "action_done":
            let failures = details["failed"] as? [[String: Any]] ?? []
            let successes = details["success"] as? [[String: Any]] ?? []
            guard !successes.isEmpty || !failures.isEmpty else { throw Failure.malformed }
            return HAReply(status: failures.isEmpty ? "Action completed" : "Some targets failed; check Home Assistant", speech: speech)
        case "query_answer": return HAReply(status: "Answer received", speech: speech)
        case "error": return HAReply(status: "Not completed: " + (details["code"] as? String ?? "unknown"), speech: speech)
        default: throw Failure.malformed
        }
    }
}
