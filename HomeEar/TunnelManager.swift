import Foundation
import AppKit

@MainActor final class TunnelManager: ObservableObject {
    @Published private(set) var state = "Not connected"
    @Published private(set) var loginURL: URL?
    @Published private(set) var loginCode = ""
    private var process: Process?
    private var output: Pipe?
    private var requestedStop = false
    private var capture = ""
    private var mode = ""
    private var reconnects = 0

    private var node: URL? { Bundle.main.url(forResource: "node", withExtension: nil, subdirectory: "Runtime") }
    private var cli: URL? { Bundle.main.url(forResource: "poke.cjs", withExtension: nil, subdirectory: "Runtime") }
    private var credentialURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/poke/credentials.json")
    }
    var hasCredentials: Bool { FileManager.default.fileExists(atPath: credentialURL.path) }

    func start() {
        guard process == nil else { return }
        guard hasCredentials else { login(); return }
        run(["tunnel", "http://127.0.0.1:3000/mcp", "-n", "HomeEar Voice"], mode: "tunnel")
    }
    func login() {
        guard process == nil else { return }
        loginCode = ""
        loginURL = nil
        run(["login", "--no-browser"], mode: "login")
    }
    func openLogin() {
        if let loginURL { NSWorkspace.shared.open(loginURL) }
    }
    func stop() {
        requestedStop = true
        process?.terminate()
        process = nil
        output = nil
        state = "Tunnel stopped"
    }
    private func run(_ arguments: [String], mode: String) {
        guard let node, let cli else {
            state = "Bundled Poke runtime is missing. Reinstall a complete HomeEar build."
            return
        }
        requestedStop = false
        self.mode = mode
        capture = ""
        let task = Process()
        task.executableURL = node
        task.arguments = [cli.path] + arguments
        task.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": node.deletingLastPathComponent().path + ":/usr/bin:/bin"
        ]) { _, new in new }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor in self?.consume(data) }
        }
        task.terminationHandler = { [weak self] ended in
            Task { @MainActor in self?.finished(ended.terminationStatus) }
        }
        do {
            try task.run()
            process = task
            output = pipe
            state = mode == "login" ? "Waiting for Poke sign-in" : "Connecting Poke voice tunnel..."
        } catch { state = "Poke runtime could not start: \(error.localizedDescription)" }
    }
    private func consume(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8) else { return }
        capture = String((capture + chunk).suffix(3000))
        if mode == "login" {
            let pattern = #"https://poke\.com/device\?code=[A-Za-z0-9%_-]+"#
            if let range = capture.range(of: pattern, options: .regularExpression),
               let url = URL(string: String(capture[range])) {
                loginURL = url
                state = "Sign in to Poke in your browser, then return here"
            }
            if let range = capture.range(of: #"Your login code is:\s*([A-Za-z0-9-]+)"#, options: .regularExpression) {
                loginCode = String(capture[range]).replacingOccurrences(of: "Your login code is:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else if capture.localizedCaseInsensitiveContains("connected") || capture.localizedCaseInsensitiveContains("tunnel active") {
            state = "Poke voice tunnel connected"
            reconnects = 0
        }
    }
    private func finished(_ code: Int32) {
        output?.fileHandleForReading.readabilityHandler = nil
        output = nil
        process = nil
        guard !requestedStop else { return }
        if mode == "login" {
            if code == 0 && hasCredentials {
                state = "Poke signed in; connecting voice tunnel"
                reconnects = 0
                start()
            } else { state = "Poke sign-in did not complete. Retry sign-in." }
            return
        }
        if !hasCredentials { state = "Poke sign-in needed"; return }
        guard reconnects < 3 else { state = "Poke tunnel stopped. Tap Reconnect."; return }
        reconnects += 1
        state = "Tunnel disconnected; retrying (\(reconnects)/3)"
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(reconnects * 5)))
            self?.start()
        }
    }
}
