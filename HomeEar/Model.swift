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
    let backend: any AgentBackend = PokeBackend()
    lazy var speech = AppleSpeechEngine(state: self)
    lazy var tts = VoiceOutput(state: self)
    lazy var mcp = MCPServer(state: self)
    let tunnel = TunnelManager()
    let updates = UpdateChecker()

    init() {
        router.onDeliver = { [weak self] text, source in self?.forwardToPoke(text: text, source: source) }
        router.onDecision = { [weak self] decision in self?.latestDecision = decision }
        router.onCommandModeChanged = { [weak self] active in
            guard let self else { return }
            self.speechState = active ? "Listening for command…" : (self.microphoneOn ? "Listening on device" : "Paused")
        }
        Task { @MainActor in
            do { try mcp.start(); if completedSetup { tunnel.start() } }
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
    private func forwardToPoke(text: String, source: FilterSource) {
        latestDecision = "\(source.rawValue) → forwarded to Poke"
        guard completedSetup else { return }
        Task {
            do {
                try await backend.send(text)
                apiState = "Delivered to Poke"
            } catch {
                apiState = "Forwarding unavailable: \(error.localizedDescription)"
            }
        }
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
