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
                        Text("HomeEar forwards likely requests automatically when listening. You can pause the microphone from the menu bar.")
                        Toggle("Start at login", isOn: Binding(get: { state.startAtLogin }, set: { state.setLogin($0) }))
                        Toggle("Strict request filter", isOn: $state.strictFilter)
                        Text("Voice replies require Poke CLI (Node.js). Sign in with npx poke@latest login in Terminal first. Outbound forwarding works without the tunnel.").font(.caption).foregroundStyle(.secondary)
                        Button("Start Poke voice tunnel") { state.tunnel.start() }
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
                        NSApplication.shared.keyWindow?.close()
                    }.buttonStyle(.borderedProminent).disabled(KeyStore.load() == nil)
                }
            }
        }.padding(30)
    }
}
