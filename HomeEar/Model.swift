import Foundation
import AppKit
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

struct RequestRecord: Identifiable {
    let id = UUID()
    let text: String
    let source: FilterSource
    let date: Date
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
    @Published var customKeywords = UserDefaults.standard.string(forKey: "customKeywords") ?? "" {
        didSet { UserDefaults.standard.set(customKeywords, forKey: "customKeywords") }
    }
    @Published var audioCuesEnabled = UserDefaults.standard.object(forKey: "audioCuesEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(audioCuesEnabled, forKey: "audioCuesEnabled") }
    }
    let levels = AudioLevelTracker()
    /// Words from Home Assistant room and device names; cached so the filter works offline.
    @Published var haWords = Set(UserDefaults.standard.stringArray(forKey: "haVocabularyWords") ?? [])
    @Published var haVocabularyState = ""
    @Published var useHAVocabulary = UserDefaults.standard.object(forKey: "useHAVocabulary") as? Bool ?? true {
        didSet { UserDefaults.standard.set(useHAVocabulary, forKey: "useHAVocabulary") }
    }
    private var haVocabularyBusy = false
    @Published var speakReplies = UserDefaults.standard.object(forKey: "speakReplies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speakReplies, forKey: "speakReplies") }
    }
    @Published var followUpEnabled = UserDefaults.standard.object(forKey: "followUpEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(followUpEnabled, forKey: "followUpEnabled") }
    }
    @Published var confirmSensitive = UserDefaults.standard.object(forKey: "confirmSensitive") as? Bool ?? true {
        didSet { UserDefaults.standard.set(confirmSensitive, forKey: "confirmSensitive") }
    }
    @Published var sensitiveWords = UserDefaults.standard.string(forKey: "sensitiveWords") ?? "" {
        didSet { UserDefaults.standard.set(sensitiveWords, forKey: "sensitiveWords") }
    }
    @Published var quickPhrases: [QuickPhrase] = {
        guard let data = UserDefaults.standard.data(forKey: "quickPhrases"),
              let list = try? JSONDecoder().decode([QuickPhrase].self, from: data) else { return [] }
        return list
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(quickPhrases) { UserDefaults.standard.set(data, forKey: "quickPhrases") }
        }
    }
    /// What HomeEar heard and did this session. Memory only.
    @Published var activity = ActivityLog()
    /// Learned corrections, stored as hashes of sentences (see FilterFeedback).
    @Published var feedback: FilterFeedback = {
        guard let data = UserDefaults.standard.data(forKey: "filterFeedback"),
              let value = try? JSONDecoder().decode(FilterFeedback.self, from: data) else { return FilterFeedback() }
        return value
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(feedback) { UserDefaults.standard.set(data, forKey: "filterFeedback") }
        }
    }
    @Published var playSounds = UserDefaults.standard.bool(forKey: "playSounds") {
        didSet { UserDefaults.standard.set(playSounds, forKey: "playSounds") }
    }
    /// True while the router waits for speech without a wake word (command, follow-up, answer).
    @Published private(set) var capturing = false
    /// A result that briefly replaces the steady menu bar icon (sent, error).
    @Published private(set) var flash: AssistantPhase?
    private var flashToken = 0
    /// Our own sounds reach the microphone too; input is ignored until this time.
    private var soundGuardUntil: TimeInterval = 0
    var menuBarPhase: AssistantPhase {
        AssistantPhase.resolve(microphoneOn: microphoneOn, capturing: capturing, flash: flash)
    }
    @Published var askWhenUnsure = UserDefaults.standard.object(forKey: "askWhenUnsure") as? Bool ?? true {
        didSet { UserDefaults.standard.set(askWhenUnsure, forKey: "askWhenUnsure") }
    }
    /// A request the router is unsure about and has asked the user to confirm.
    @Published var pendingConfirmation: PendingRequest?
    /// Home Assistant keeps context for follow-ups while the same conversation id is reused.
    private var haConversationID: String?
    private var haConversationAt: TimeInterval = 0
    private var echoGuard = EchoGuard()
    private var ttsStateBeforeSpeaking: String?
    @Published var householdNames = UserDefaults.standard.string(forKey: "householdNames") ?? "" {
        didSet { UserDefaults.standard.set(householdNames, forKey: "householdNames") }
    }
    @Published var quietHoursEnabled = UserDefaults.standard.bool(forKey: "quietHoursEnabled") {
        didSet { UserDefaults.standard.set(quietHoursEnabled, forKey: "quietHoursEnabled"); evaluateQuietHours() }
    }
    @Published var quietStart = UserDefaults.standard.object(forKey: "quietStart") as? Int ?? 23 {
        didSet { UserDefaults.standard.set(quietStart, forKey: "quietStart"); evaluateQuietHours() }
    }
    @Published var quietEnd = UserDefaults.standard.object(forKey: "quietEnd") as? Int ?? 7 {
        didSet { UserDefaults.standard.set(quietEnd, forKey: "quietEnd"); evaluateQuietHours() }
    }
    /// Last requests this session, newest first. Memory only, never written to disk.
    @Published var recent: [RequestRecord] = []
    private var pausedByQuietHours = false
    private var wasQuiet = false
    private var quietTimer: Timer?
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
        router.voiceProfile.referenceSNR = UserDefaults.standard.object(forKey: "voiceReferenceSNR") as? Double
        router.onVoiceReferenceChanged = { UserDefaults.standard.set($0, forKey: "voiceReferenceSNR") }
        router.onEvent = { [weak self] entry in self?.activity.add(entry) }
        router.onAskBack = { [weak self] pending in self?.askBack(pending) }
        router.onPendingChanged = { [weak self] pending in self?.pendingConfirmation = pending }
        router.onDeliver = { [weak self] text, source in self?.forwardRequest(text: text, source: source) }
        router.onDecision = { [weak self] decision in self?.latestDecision = decision }
        router.onCommandModeChanged = { [weak self] active in
            guard let self else { return }
            self.capturing = active
            self.speechState = active ? "Listening for command…" : (self.microphoneOn ? "Listening on device" : "Paused")
            if active { self.play(.heard) }
        }
        // Launching inside a quiet window must not pause a mic the user starts by hand.
        wasQuiet = quietHoursEnabled && QuietHours(startHour: quietStart, endHour: quietEnd).contains(Date())
        quietTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateQuietHours() }
        }
        haVocabularyState = haWords.isEmpty ? "Not imported" : "\(haWords.count) words imported"
        // Refresh quietly at launch, but only after the user imported once.
        if !haWords.isEmpty { importHAVocabulary(silent: true) }
        Task { @MainActor in
            do { try mcp.start(); if completedSetup && selectedBackend == "poke" { tunnel.start() } }
            catch { ttsState = "Local tool unavailable: \(error.localizedDescription)" }
        }
    }
    func start() {
        guard !microphoneOn else { return }
        pausedByQuietHours = false
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
        pausedByQuietHours = false
        speech.stop()
        router.reset()
        microphoneOn = false
        speechState = "Paused"
    }
    /// Called by VoiceOutput so the microphone input is ignored while we talk.
    func speechDidBegin() {
        echoGuard.began(at: ProcessInfo.processInfo.systemUptime)
        if ttsState != "Speaking" { ttsStateBeforeSpeaking = ttsState }
        ttsState = "Speaking"
    }
    func speechDidEnd(expectsAnswer: Bool) {
        echoGuard.ended(at: ProcessInfo.processInfo.systemUptime)
        ttsState = ttsStateBeforeSpeaking ?? "Ready"
        ttsStateBeforeSpeaking = nil
        // The reply is out; the next few seconds may hold an answer or a follow-up.
        if microphoneOn { router.openFollowUp(expectsAnswer: expectsAnswer) }
    }
    /// Briefly shows a result in the menu bar icon, then goes back to the steady state.
    private func showFlash(_ phase: AssistantPhase, for seconds: TimeInterval) {
        flashToken += 1
        let token = flashToken
        flash = phase
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if flashToken == token { flash = nil }
        }
    }
    private func play(_ cue: SoundCue) {
        guard playSounds, let sound = NSSound(named: NSSound.Name(cue.systemSoundName)) else { return }
        soundGuardUntil = ProcessInfo.processInfo.systemUptime + 1.0
        sound.play()
    }
    private func reportFailure() {
        showFlash(.error, for: 4)
        play(.error)
    }
    private func askBack(_ pending: PendingRequest) {
        guard speakReplies else { return }
        let german = language.hasPrefix("de")
        let prompt = pending.sensitive
            ? (german ? "Soll ich das wirklich tun: \(pending.text)?" : "Do you really want me to: \(pending.text)?")
            : (german ? "Meintest du: \(pending.text)?" : "Did you mean: \(pending.text)?")
        tts.speak(prompt, expectsAnswer: true)
    }
    func receive(_ text: String, isFinal: Bool) {
        // Our own voice or sounds coming back through the microphone are not a request.
        let now = ProcessInfo.processInfo.systemUptime
        if echoGuard.shouldDrop(at: now) || now < soundGuardUntil { return }
        latestText = text
        router.config.wakeWordEnabled = wakeWordEnabled
        router.config.proactiveEnabled = proactiveEnabled
        router.config.strictFilter = strictFilter
        var extra = RequestFilter.parseKeywords(customKeywords)
        if useHAVocabulary { extra.formUnion(haWords) }
        router.config.extraEntities = extra
        router.config.addressees = RequestFilter.parseKeywords(householdNames)
        router.config.audioCuesEnabled = audioCuesEnabled
        router.config.followUpEnabled = followUpEnabled
        router.config.askWhenUnsure = askWhenUnsure
        router.config.confirmSensitive = confirmSensitive
        router.config.quickPhrases = quickPhrases
        router.config.feedback = feedback
        router.config.extraSensitive = RequestFilter.parseKeywords(sensitiveWords)
        let features = isFinal && audioCuesEnabled ? levels.snapshot(at: ProcessInfo.processInfo.systemUptime) : nil
        router.receive(text, isFinal: isFinal, audio: features)
    }
    private func forwardRequest(text: String, source: FilterSource) {
        // Capture the selected destination before suspension: one request, one backend.
        let destination = selectedBackend
        guard completedSetup || destination == "home_assistant" else { return }
        activity.add(ActivityEntry(date: Date(), text: text, outcome: .sent,
                                   reason: "Sent to \(destination == "poke" ? "Poke" : "Home Assistant")", source: source))
        showFlash(.sent, for: 1.5)
        play(.sent)
        recent.removeAll { $0.text == text }
        recent.insert(RequestRecord(text: text, source: source, date: Date()), at: 0)
        if recent.count > 5 { recent.removeLast(recent.count - 5) }
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
                    let now = ProcessInfo.processInfo.systemUptime
                    let conversation = now - haConversationAt < 45 ? haConversationID : nil
                    let response = try await client.process(text, language: locale, conversationID: conversation)
                    haConversationID = response.conversationID
                    haConversationAt = ProcessInfo.processInfo.systemUptime
                    haResponse = response.speech
                    haState = response.status
                    latestDecision = "Home Assistant: \(response.status)"
                    if speakReplies, !response.speech.isEmpty {
                        tts.speak(response.speech, expectsAnswer: response.expectsFollowUp)
                    } else if response.expectsFollowUp, microphoneOn {
                        router.openFollowUp(expectsAnswer: true)
                    }
                } catch {
                    // Never retry a command after a timeout: it might have executed.
                    haState = error.localizedDescription
                    latestDecision = "Home Assistant: result unconfirmed; no retry"
                    reportFailure()
                }
            }
        } else {
            latestDecision = "\(source.rawValue) → sending to Poke"
            Task {
                do {
                    try await PokeBackend().send(text)
                    apiState = "Delivered to Poke"
                    latestDecision = "\(source.rawValue) → sent to Poke"
                } catch {
                    apiState = "Forwarding unavailable: \(error.localizedDescription)"
                    reportFailure()
                }
            }
        }
    }
    /// Activity list: the filter held this back, but the user wants it sent. Remembered for that exact sentence.
    func sendAnyway(_ entry: ActivityEntry) {
        if SensitiveActions.match(in: entry.text, extra: RequestFilter.parseKeywords(sensitiveWords)) == nil {
            feedback.record(.send, for: entry.text)
        }
        router.sendManually(entry.text)
    }
    /// Activity list: this was sent but should not have been. The exact sentence is ignored from now on.
    func markNotACommand(_ entry: ActivityEntry) {
        feedback.record(.ignore, for: entry.text)
    }
    func clearActivity() { activity.clear() }
    func clearFeedback() { feedback.removeAll() }
    /// Sends a previous request again on the currently selected backend.
    func resend(_ record: RequestRecord) {
        forwardRequest(text: record.text, source: record.source)
    }
    /// Pauses the microphone when a quiet window begins and resumes it when
    /// the window ends, but only if quiet hours did the pausing.
    func evaluateQuietHours(now: Date = Date()) {
        let quiet = quietHoursEnabled && QuietHours(startHour: quietStart, endHour: quietEnd).contains(now)
        defer { wasQuiet = quiet }
        if quiet && !wasQuiet && microphoneOn {
            stop()
            pausedByQuietHours = true
            speechState = "Paused for quiet hours"
        } else if !quiet && wasQuiet && pausedByQuietHours {
            start()
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
    /// Reads room and device names from Home Assistant so the filter recognises
    /// requests that use your own names ("mach die Lesecke an").
    func importHAVocabulary(silent: Bool = false) {
        guard !haVocabularyBusy else { return }
        guard let token = HATokenStore.load(), !token.isEmpty else {
            if !silent { haVocabularyState = "Save a token first" }
            return
        }
        let server = haURL
        haVocabularyBusy = true
        if !silent { haVocabularyState = "Importing..." }
        Task {
            defer { haVocabularyBusy = false }
            do {
                let client = try HomeAssistantClient(server: server, token: token)
                let names = try await client.fetchVocabulary()
                let words = RequestFilter.vocabularyWords(from: names)
                haWords = words
                UserDefaults.standard.set(words.sorted(), forKey: "haVocabularyWords")
                haVocabularyState = "\(words.count) words from \(names.count) rooms and devices"
            } catch HomeAssistantClient.Failure.resultUnconfirmed {
                if !silent { haVocabularyState = "Could not reach Home Assistant." }
            } catch {
                if !silent { haVocabularyState = error.localizedDescription }
            }
        }
    }
    func clearHAVocabulary() {
        haWords = []
        UserDefaults.standard.removeObject(forKey: "haVocabularyWords")
        haVocabularyState = "Not imported"
    }
    func speakHAResponse() {
        guard !haResponse.isEmpty else { return }
        // No need to pause the microphone: input is ignored while we speak.
        tts.speak(haResponse)
        latestDecision = "Reading Home Assistant reply"
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
    /// Reuse this id on the next request to keep context ("und im Flur auch").
    var conversationID: String?
    /// Home Assistant (or the wording of the reply) expects an answer.
    var expectsFollowUp = false
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
    /// Room names and the names of controllable devices, for the request filter.
    /// A read-only template call; nothing in Home Assistant is changed.
    func fetchVocabulary() async throws -> [String] {
        let body = try JSONSerialization.data(withJSONObject: ["template": Self.vocabularyTemplate])
        let data = try await perform(request(path: "api/template", method: "POST", body: body))
        return try Self.parseVocabulary(data)
    }
    private static let vocabularyTemplate = #"{{ {"areas": areas() | map("area_name") | list, "names": states | selectattr("domain", "in", ["light","switch","cover","climate","fan","media_player","scene","script","lock","vacuum","humidifier","input_boolean"]) | map(attribute="name") | list} | tojson }}"#
    static func parseVocabulary(_ data: Data) throws -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw Failure.malformed }
        let areas = object["areas"] as? [String] ?? []
        let names = object["names"] as? [String] ?? []
        guard !(areas.isEmpty && names.isEmpty) else { throw Failure.malformed }
        return areas + names
    }
    func testConnection() async throws {
        let data = try await perform(request(path: "api/"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["message"] as? String == "API running." else { throw Failure.malformed }
    }
    func process(_ text: String, language: String, conversationID: String? = nil) async throws -> HAReply {
        var payload: [String: Any] = ["text": text, "language": language, "agent_id": "home_assistant"]
        if let conversationID { payload["conversation_id"] = conversationID }
        let body = try JSONSerialization.data(withJSONObject: payload)
        let data = try await perform(request(path: "api/conversation/process", method: "POST", body: body))
        return try Self.parseReply(data)
    }
    static func parseReply(_ data: Data) throws -> HAReply {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let response = object["response"] as? [String: Any],
              let type = response["response_type"] as? String else { throw Failure.malformed }
        let speech = ((response["speech"] as? [String: Any])?["plain"] as? [String: Any])?["speech"] as? String ?? ""
        let details = response["data"] as? [String: Any] ?? [:]
        let expects = object["continue_conversation"] as? Bool
            ?? speech.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?")
        func reply(_ status: String) -> HAReply {
            HAReply(status: status, speech: speech, conversationID: object["conversation_id"] as? String,
                    expectsFollowUp: expects)
        }
        switch type {
        case "action_done":
            let failures = details["failed"] as? [[String: Any]] ?? []
            let successes = details["success"] as? [[String: Any]] ?? []
            guard !successes.isEmpty || !failures.isEmpty else { throw Failure.malformed }
            return reply(failures.isEmpty ? "Action completed" : "Some targets failed; check Home Assistant")
        case "query_answer": return reply("Answer received")
        case "error": return reply("Not completed: " + (details["code"] as? String ?? "unknown"))
        default: throw Failure.malformed
        }
    }
}
