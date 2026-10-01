import SwiftUI
import AVFoundation

struct OnboardingView: View {
    @ObservedObject var state: AppState
    @State private var step = 0
    @State private var key = ""
    @State private var showKey = false
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Image(systemName: "waveform.circle.fill").font(.system(size: 35)).foregroundStyle(.teal)
                VStack(alignment: .leading) {
                    Text("HomeEar").font(.title2.bold())
                    Text("Your private voice gateway").foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(step + 1) of 4").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(step + 1), total: 4).tint(.teal)
            Group {
                switch step {
                case 0:
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Listen locally").font(.title.bold())
                        Text("HomeEar transcribes on your Mac. Only text that looks like a request is sent to Poke. It can still mishear background speech, so pause it when you need privacy.")
                        Label("Audio is not saved", systemImage: "lock.shield")
                        Label("German speech is selected by default", systemImage: "globe")
                        Text("A language model may download on first use.").font(.caption).foregroundStyle(.secondary)
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Set your language").font(.title.bold())
                        Text("HomeEar needs microphone and Speech Recognition access.")
                        Picker("Speech language", selection: $state.language) {
                            Text("German (Germany)").tag("de-DE")
                            Text("English (US)").tag("en-US")
                        }.onChange(of: state.language) { _, new in state.saveLanguage(new) }
                        Button("Enable microphone and speech") { state.start() }.buttonStyle(.borderedProminent)
                        Text(state.speechState).font(.caption).foregroundStyle(.secondary)
                    }
                case 2:
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Connect Poke").font(.title.bold())
                        Text("Requests are forwarded to your Poke agent once your API key is saved. The key stays in macOS Keychain.")
                        HStack {
                            Group { if showKey { TextField("Poke V2 API key", text: $key) } else { SecureField("Poke V2 API key", text: $key) } }
                                .textFieldStyle(.roundedBorder)
                            Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                        }
                        Button("Save key") {
                            if KeyStore.save(key) { key = ""; state.apiState = "Key saved; ready to forward" }
                            else { state.apiState = "Could not store key in Keychain" }
                        }.disabled(key.isEmpty)
                        Text(state.apiState).font(.caption).foregroundStyle(.secondary)
                    }
                default:
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Ready to listen").font(.title.bold())
                        Text("Say “Hey Poke” followed by a request — or just speak a likely command and HomeEar forwards it automatically. You can pause the microphone from the menu bar.")
                        Toggle("Start at login", isOn: Binding(get: { state.startAtLogin }, set: { state.setLogin($0) }))
                        Toggle("“Hey Poke” wake word", isOn: $state.wakeWordEnabled)
                        Toggle("Proactive request filter", isOn: $state.proactiveEnabled)
                        Toggle("Strict request filter", isOn: $state.strictFilter)
                        Text("The Poke runtime is included. Sign in once through your browser; HomeEar starts the voice tunnel and reconnects it automatically. Outbound requests still work if the tunnel is offline.").font(.caption).foregroundStyle(.secondary)
                        Button(state.tunnel.hasCredentials ? "Connect voice tunnel" : "Sign in to Poke") { state.tunnel.start() }
                        if state.tunnel.loginURL != nil {
                            Button("Open Poke sign-in") { state.tunnel.openLogin() }
                            if !state.tunnel.loginCode.isEmpty { Text("Code: \(state.tunnel.loginCode)").font(.caption.monospaced()) }
                        }
                        Text(state.tunnel.state).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 3 { Button("Continue") { step += 1 }.buttonStyle(.borderedProminent) }
                else {
                    Button("Finish setup") {
                        state.completedSetup = true
                        UserDefaults.standard.set(true, forKey: "setupComplete")
                        if !state.microphoneOn { state.start() }
                        state.tunnel.start()
                        NSApplication.shared.keyWindow?.close()
                    }.buttonStyle(.borderedProminent).disabled(KeyStore.load() == nil)
                }
            }
        }.padding(30)
    }
}
