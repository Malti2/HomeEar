import Foundation

@MainActor final class TunnelManager: ObservableObject {
    @Published private(set) var state = "Not connected"
    private var process: Process?
    private var output: Pipe?

    func start() {
        guard process == nil else { return }
        let candidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            state = "Node.js is required. Install it, then sign in using npx poke@latest login."
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["poke@latest", "tunnel", "http://127.0.0.1:3000/mcp", "-n", "HomeEar Voice"]
        task.environment = ProcessInfo.processInfo.environment.merging([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        ]) { _, new in new }
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.terminationHandler = { [weak self] terminated in
            Task { @MainActor in
                self?.process = nil
                self?.output = nil
                self?.state = "Tunnel stopped (exit \(terminated.terminationStatus)). Check Poke CLI login."
            }
        }
        do {
            try task.run()
            process = task
            output = pipe
            state = "Tunnel starting; verify connection in Poke"
        } catch { state = "Tunnel failed: \(error.localizedDescription)" }
    }
    func stop() {
        guard let process else { return }
        process.terminate()
        self.process = nil
        output = nil
        state = "Tunnel stopped"
    }
}
