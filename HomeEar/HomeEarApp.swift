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
                .frame(minWidth: 640, minHeight: 440)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 740, height: 520)
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
            if let pending = state.pendingConfirmation {
                VStack(alignment: .leading, spacing: 8) {
                    Text(pending.sensitive ? "CONFIRM" : "DID YOU MEAN?").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    Text(pending.text).font(.subheadline).lineLimit(3)
                    HStack {
                        Button("Send") { state.router.confirmPending() }.buttonStyle(.borderedProminent)
                        Button("Discard") { state.router.discardPending() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
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
            if state.selectedBackend == "home_assistant" && !state.haResponse.isEmpty {
                Text(state.haResponse).font(.callout).lineLimit(4)
                Button("Read reply again") { state.speakHAResponse() }
            }
            if !state.recent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("RECENT REQUESTS").font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    ForEach(state.recent.prefix(3)) { record in
                        HStack(spacing: 8) {
                            Text(record.text).font(.caption).lineLimit(1).truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button { state.resend(record) } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless)
                                .help("Send this request again")
                        }
                    }
                }
            }
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


enum SettingsPane: String, CaseIterable, Identifiable {
    case general, speech, filter, poke, homeAssistant, update
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .speech: "Speech"
        case .filter: "Request Filter"
        case .poke: "Poke"
        case .homeAssistant: "Home Assistant"
        case .update: "Update"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .speech: "waveform"
        case .filter: "line.3.horizontal.decrease.circle"
        case .poke: "paperplane"
        case .homeAssistant: "house"
        case .update: "arrow.triangle.2.circlepath"
        }
    }
}

/// Configuration is separate from the first-run setup flow. Sidebar of
/// categories with one grouped form per pane, like System Settings.
struct HomeEarSettingsView: View {
    @ObservedObject var state: AppState
    @State private var selection: SettingsPane?
    @State private var key = ""
    @State private var revealKey = false
    @State private var haToken = ""

    init(state: AppState, initialPane: SettingsPane = .general) {
        self.state = state
        _selection = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label(pane.title, systemImage: pane.symbol).tag(pane)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 220)
        } detail: {
            let pane = selection ?? .general
            Group {
                switch pane {
                case .general: generalPane
                case .speech: speechPane
                case .filter: filterPane
                case .poke: pokePane
                case .homeAssistant: homeAssistantPane
                case .update: updatePane
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func hourLabel(_ hour: Int) -> String { hour < 10 ? "0\(hour):00" : "\(hour):00" }

    // MARK: panes

    private var generalPane: some View {
        Form {
            Section {
                Picker("Send requests to", selection: $state.selectedBackend) {
                    Text("Poke").tag("poke")
                    Text("Home Assistant").tag("home_assistant")
                }.pickerStyle(.segmented)
            } header: { Text("Destination") } footer: {
                note("Only the selected backend receives your requests. There is no automatic fallback.")
            }
            Section("Startup") {
                Toggle("Start at login", isOn: Binding(get: { state.startAtLogin }, set: { state.setLogin($0) }))
            }
            Section {
                Toggle("Pause microphone during quiet hours", isOn: $state.quietHoursEnabled)
                if state.quietHoursEnabled {
                    Picker("From", selection: $state.quietStart) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Picker("Until", selection: $state.quietEnd) {
                        ForEach(0..<24, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                }
            } header: { Text("Quiet hours") } footer: {
                note("The microphone pauses when the window starts and resumes when it ends, unless you paused it yourself.")
            }
        }
    }

    private var speechPane: some View {
        Form {
            Section {
                Picker("Language", selection: Binding(get: { state.language }, set: { state.saveLanguage($0) })) {
                    Text("German (Germany)").tag("de-DE")
                    Text("English (US)").tag("en-US")
                }
                LabeledContent("Status", value: state.speechState)
                Button(state.microphoneOn ? "Pause microphone" : "Start microphone") {
                    state.microphoneOn ? state.stop() : state.start()
                }
            } header: { Text("Recognition") } footer: {
                note("Apple recognition runs on this Mac in fast live mode. Only finalized requests are sent to your selected backend.")
            }
            Section {
                Toggle("Speak replies aloud", isOn: $state.speakReplies)
            } header: { Text("Replies") } footer: {
                note("Home Assistant answers are read aloud. While HomeEar speaks, and for a moment after, microphone input is ignored so it never hears itself. Poke speaks through its own voice tool either way.")
            }
            Section {
                Toggle("Keep listening after a reply", isOn: $state.followUpEnabled)
                Toggle("Ask when unsure", isOn: $state.askWhenUnsure)
            } header: { Text("Conversation") } footer: {
                note("After a spoken reply, a short answer or follow-up (\"und im Flur auch\") works without the wake word for a few seconds. When a request is almost, but not quite, a command, HomeEar asks \"Did you mean …?\" and waits for yes or no instead of guessing.")
            }
            Section {
                Toggle("Hey Poke wake word", isOn: $state.wakeWordEnabled)
                Toggle("Proactive requests", isOn: $state.proactiveEnabled)
            } header: { Text("Activation") } footer: {
                note("The wake word always sends what follows. Proactive requests are spoken commands without a wake word that pass the request filter.")
            }
        }
    }

    private var filterPane: some View {
        Form {
            Section {
                Toggle("Strict request filter", isOn: $state.strictFilter)
                Toggle("Ignore distant speech (TV, other rooms)", isOn: $state.audioCuesEnabled)
            } header: { Text("Sensitivity") } footer: {
                note("Strict needs a clearer command before sending. Distant speech compares loudness to the room and to your own \"Hey Poke\" voice; only loudness is measured, and it can lower a score but never send a request on its own.")
            }
            Section {
                TextField("Extra smart-home words", text: $state.customKeywords, prompt: Text("ventilator, kamin"))
            } header: { Text("Your words") } footer: {
                note("Comma separated. These make a sentence count as a home request in the proactive filter.")
            }
            Section {
                TextField("Names of people at home", text: $state.householdNames, prompt: Text("Anna, Ben"))
            } header: { Text("People at home") } footer: {
                note("A sentence that starts or ends with one of these names (\"Anna, mach das Licht an\") is meant for them and is not sent.")
            }
            Section {
                Toggle("Confirm sensitive actions", isOn: $state.confirmSensitive)
                TextField("Extra sensitive words", text: $state.sensitiveWords, prompt: Text("pool, tresor"))
            } header: { Text("Safety") } footer: {
                note("Locks, garage doors, alarm systems and ovens are never sent from background speech. With \"Hey Poke\" they ask for a yes first. Add your own words, comma separated.")
            }
            Section {
                LabeledContent("Imported", value: state.haVocabularyState)
                Toggle("Use imported names in the filter", isOn: $state.useHAVocabulary)
                HStack {
                    Button("Import room and device names") { state.importHAVocabulary() }
                    if !state.haWords.isEmpty { Button("Clear") { state.clearHAVocabulary() } }
                }
            } header: { Text("Home Assistant names") } footer: {
                note("Reads room and device names once (read-only) and caches the words on this Mac, so the filter knows words like \"Lesecke\" or \"Stehlampe\". Needs the Home Assistant connection. Refreshed quietly at launch after the first import.")
            }
        }
    }

    private var pokePane: some View {
        Form {
            Section {
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
                LabeledContent("API", value: state.apiState)
            } header: { Text("API key") } footer: {
                note("Leave blank to keep your saved key. Keys stay in macOS Keychain.")
            }
            Section("Voice tunnel") {
                LabeledContent("Status", value: state.tunnel.state)
                Button(state.tunnel.hasCredentials ? "Reconnect voice tunnel" : "Sign in to Poke") { state.tunnel.start() }
                if state.tunnel.loginURL != nil {
                    Button("Open Poke sign-in") { state.tunnel.openLogin() }
                    if !state.tunnel.loginCode.isEmpty { Text("Code: \(state.tunnel.loginCode)").font(.caption.monospaced()) }
                }
            }
            Section("Voice") {
                TextField("Voice identifier (optional)", text: $state.voiceID)
                    .onChange(of: state.voiceID) { _, value in UserDefaults.standard.set(value, forKey: "voiceID") }
            }
        }
    }

    private var homeAssistantPane: some View {
        Form {
            Section {
                TextField("Server URL", text: $state.haURL, prompt: Text("https://..."))
                SecureField("Long-lived access token", text: $haToken)
                HStack {
                    Button("Save token") {
                        if state.saveHAToken(haToken) { haToken = "" }
                    }.disabled(haToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(state.haTesting ? "Checking..." : "Test connection") { state.testHomeAssistant() }
                        .disabled(state.haTesting)
                }
                LabeledContent("Status", value: state.haState)
            } header: { Text("Server") } footer: {
                note("The token stays in Keychain. Use HTTPS or a private VPN address. Assist uses the selected speech language; no paid AI calls.")
            }
            if !state.haResponse.isEmpty {
                Section("Last reply") {
                    Text(state.haResponse).font(.callout)
                    Button("Read reply again") { state.speakHAResponse() }
                }
            }
        }
    }

    private var updatePane: some View {
        Form {
            Section { UpdateSettingsView(updates: state.updates) }
        }
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
                    ("settings-general", AnyView(HomeEarSettingsView(state: state, initialPane: .general).preferredColorScheme(.dark)), NSSize(width: 740, height: 520)),
                    ("settings-speech", AnyView(HomeEarSettingsView(state: state, initialPane: .speech).preferredColorScheme(.dark)), NSSize(width: 740, height: 520)),
                    ("settings-filter", AnyView(HomeEarSettingsView(state: state, initialPane: .filter).preferredColorScheme(.dark)), NSSize(width: 740, height: 760)),
                    ("settings-poke", AnyView(HomeEarSettingsView(state: state, initialPane: .poke).preferredColorScheme(.dark)), NSSize(width: 740, height: 560)),
                    ("settings-assist", AnyView(HomeEarSettingsView(state: state, initialPane: .homeAssistant).preferredColorScheme(.dark)), NSSize(width: 740, height: 520)),
                    ("settings-update", AnyView(HomeEarSettingsView(state: state, initialPane: .update).preferredColorScheme(.dark)), NSSize(width: 740, height: 520)),
                    ("onboarding", AnyView(OnboardingView(state: state).preferredColorScheme(.dark)), NSSize(width: 560, height: 470))
                ]
                var captures = views
                for step in 1...3 {
                    captures.append(("setup-step-\(step + 1)", AnyView(OnboardingView(state: state, initialStep: step).preferredColorScheme(.dark)), NSSize(width: 560, height: 540)))
                }
                let haState = AppState()
                haState.selectedBackend = "home_assistant"
                captures.append(("panel-assist", AnyView(PanelView(state: haState).preferredColorScheme(.dark)), NSSize(width: 320, height: 410)))
                captures.append(("setup-assist", AnyView(OnboardingView(state: haState, initialStep: 2).preferredColorScheme(.dark)), NSSize(width: 560, height: 540)))
                let betaState = AppState()
                betaState.updates.setChannel(.beta)
                captures.append(("settings-update-beta", AnyView(HomeEarSettingsView(state: betaState, initialPane: .update).preferredColorScheme(.dark)), NSSize(width: 740, height: 560)))
                for (name, view, size) in captures {
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

struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateChecker
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
            Picker("Update channel", selection: Binding(get: { updates.channel }, set: { updates.setChannel($0) })) {
                Text("Stable").tag(UpdateChannel.stable)
                Text("Beta").tag(UpdateChannel.beta)
            }.pickerStyle(.segmented).disabled(!updates.canCheckForUpdates)
            if updates.channel == .beta {
                Label("Beta versions are unfinished and may contain bugs. Use them only if you are comfortable testing.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text(updates.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Check for updates automatically", isOn: Binding(get: { updates.automaticallyChecks }, set: { updates.setAutomaticChecks($0) }))
            HStack {
                Button("Check for updates...") { updates.check() }.disabled(!updates.canCheckForUpdates)
                Button("GitHub Releases") { updates.openRelease() }
            }

        }
    }
}
