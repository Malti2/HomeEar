import SwiftUI
import AppKit

@main struct HomeEarApp: App {
    @StateObject private var state = AppState()
    init() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        if let index = CommandLine.arguments.firstIndex(of: "--capture-ui"),
           CommandLine.arguments.indices.contains(index + 1) {
            let directory = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                DevelopmentUICapture.run(directory: directory)
            }
        }
    }
    var body: some Scene {
        MenuBarExtra("HomeEar", systemImage: state.microphoneOn ? "waveform" : "waveform.slash") {
            PanelView(state: state)
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)
        Window("HomeEar Setup", id: "setup") {
            OnboardingView(state: state)
                .frame(minWidth: 540, minHeight: 440)
                .onAppear { bringSetupForward() }
        }
        .defaultSize(width: 560, height: 470)
        Window("HomeEar Settings", id: "settings") {
            HomeEarSettingsView(state: state)
                .frame(minWidth: 520, minHeight: 480)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 560, height: 540)
    }
    private func bringSetupForward() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "HomeEar Setup" })?.makeKeyAndOrderFront(nil)
        }
    }
}

struct PanelView: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("HomeEar").font(.title3.weight(.semibold))
                Label(state.microphoneOn ? "Listening on this Mac" : "Microphone paused",
                      systemImage: state.microphoneOn ? "circle.fill" : "pause.circle")
                    .font(.caption)
                    .foregroundStyle(state.microphoneOn ? Color.green : Color.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("LAST HEARD").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                Text(state.latestText).font(.subheadline).lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !state.latestDecision.isEmpty {
                    Text(state.latestDecision).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            VStack(spacing: 12) {
                HStack {
                    Text("Speech").foregroundStyle(.secondary)
                    Spacer()
                    Text("Apple · \(state.language == "de-DE" ? "German" : "English")")
                }
                Divider()
                HStack(alignment: .top) {
                    Text(state.selectedBackend == "poke" ? "Poke" : "Home Assistant").foregroundStyle(.secondary)
                    Spacer()
                    Text(state.selectedBackend == "poke" ? state.apiState : state.haState).multilineTextAlignment(.trailing).lineLimit(2)
                }
            }.font(.caption)
            if !state.microphoneOn && state.speechState != "Not started" && state.speechState != "Paused" {
                Text(state.speechState).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(state.microphoneOn ? "Pause" : "Start listening") {
                    state.microphoneOn ? state.stop() : state.start()
                }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Settings") { presentSettings() }
            }
            HStack {
                if !state.completedSetup {
                    Button("Finish setup") { openWindow(id: "setup") }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(20)
        .preferredColorScheme(.dark)
    }
    private func presentSettings() {
        openWindow(id: "settings")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.title == "HomeEar Settings" })?.makeKeyAndOrderFront(nil)
        }
    }
}

struct StatusRow: View {
    let icon: String, label: String, value: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(.teal).frame(width: 18)
            Text(label).frame(width: 72, alignment: .leading)
            Text(value).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
        }.font(.caption)
    }
}


/// Configuration is separate from the first-run setup flow.
struct HomeEarSettingsView: View {
    @ObservedObject var state: AppState
    @State private var key = ""
    @State private var revealKey = false
    @State private var haToken = ""
    var body: some View {
        Form {
            Section("Request destination") {
                Picker("Send requests to", selection: $state.selectedBackend) {
                    Text("Poke").tag("poke")
                    Text("Home Assistant").tag("home_assistant")
                }.pickerStyle(.segmented)
                Text("Only the selected backend receives your requests. No automatic fallback.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Home Assistant") {
                TextField("Server URL (https://...)", text: $state.haURL)
                SecureField("Long-lived access token", text: $haToken)
                HStack {
                    Button("Save token") {
                        if state.saveHAToken(haToken) { haToken = "" }
                    }.disabled(haToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(state.haTesting ? "Checking..." : "Test connection") { state.testHomeAssistant() }
                        .disabled(state.haTesting)
                }
                Text("Token stays in Keychain. Use HTTPS or a private VPN address. Assist uses the selected speech language; no paid AI calls.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(state.haState).font(.caption).foregroundStyle(.secondary)
                if !state.haResponse.isEmpty {
                    Text(state.haResponse).font(.callout)
                    Button("Read reply (pauses microphone)") { state.speakHAResponse() }
                }
            }
            Section("Speech recognition") {
                Picker("Language", selection: Binding(get: { state.language }, set: { state.saveLanguage($0) })) {
                    Text("German (Germany)").tag("de-DE")
                    Text("English (US)").tag("en-US")
                }
                Toggle("Hey Poke wake word", isOn: $state.wakeWordEnabled)
                Toggle("Proactive requests", isOn: $state.proactiveEnabled)
                Toggle("Strict request filter", isOn: $state.strictFilter)
                Text("Apple recognition runs on this Mac in fast live mode. Only finalized requests are sent to your selected backend.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Status", value: state.speechState)
                Button(state.microphoneOn ? "Pause microphone" : "Start microphone") {
                    state.microphoneOn ? state.stop() : state.start()
                }
            }
            Section("Poke connection") {
                HStack {
                    Group {
                        if revealKey { TextField("Replace Poke API key", text: $key) }
                        else { SecureField("Replace Poke API key", text: $key) }
                    }
                    Toggle("Show", isOn: $revealKey).toggleStyle(.checkbox)
                }
                Button("Save new key") {
                    if KeyStore.save(key) { key = ""; state.apiState = "Key saved; ready to forward" }
                    else { state.apiState = "Could not store key in Keychain" }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Leave blank to keep your saved key. Keys stay in macOS Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("API", value: state.apiState)
                LabeledContent("Voice tunnel", value: state.tunnel.state)
                Button(state.tunnel.hasCredentials ? "Reconnect voice tunnel" : "Sign in to Poke") { state.tunnel.start() }
                if state.tunnel.loginURL != nil {
                    Button("Open Poke sign-in") { state.tunnel.openLogin() }
                    if !state.tunnel.loginCode.isEmpty { Text("Code: \(state.tunnel.loginCode)").font(.caption.monospaced()) }
                }
                TextField("Voice identifier (optional)", text: $state.voiceID)
                    .onChange(of: state.voiceID) { _, value in UserDefaults.standard.set(value, forKey: "voiceID") }
            }
            Section("General") {
                Toggle("Start at login", isOn: Binding(get: { state.startAtLogin }, set: { state.setLogin($0) }))
                Button("Check updates") { state.updates.check() }
                Text(state.updates.status).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(12)
    }
}


/// Captures the production SwiftUI views in real AppKit windows on the CI Mac.
/// Does not start the microphone, send requests, or populate sample activity.
@MainActor private enum DevelopmentUICapture {
    private static var windows: [NSWindow] = []
    static func run(directory: String) {
        let state = AppState()
        Task { @MainActor in
            do {
                try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                let views: [(String, AnyView, NSSize)] = [
                    ("panel", AnyView(PanelView(state: state).preferredColorScheme(.dark)), NSSize(width: 320, height: 410)),
                    ("settings", AnyView(HomeEarSettingsView(state: state).preferredColorScheme(.dark)), NSSize(width: 580, height: 750)),
                    ("onboarding", AnyView(OnboardingView(state: state).preferredColorScheme(.dark)), NSSize(width: 560, height: 470))
                ]
                for (name, view, size) in views {
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.title = "HomeEar " + name.capitalized
                    window.appearance = NSAppearance(named: .darkAqua)
                    window.contentView = NSHostingView(rootView: view)
                    windows.append(window)
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                    try await Task.sleep(nanoseconds: 1_500_000_000)
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), directory + "/HomeEar-" + name + ".png"]
                    try capture.run()
                    capture.waitUntilExit()
                    guard capture.terminationStatus == 0 else {
                        throw NSError(domain: "HomeEarUICapture", code: Int(capture.terminationStatus))
                    }
                    window.orderOut(nil)
                }
                print("HOME_EAR_UI_CAPTURE_SUCCEEDED")
            } catch {
                print("HOME_EAR_UI_CAPTURE_FAILED: \(error)")
            }
            NSApp.terminate(nil)
        }
    }
}
