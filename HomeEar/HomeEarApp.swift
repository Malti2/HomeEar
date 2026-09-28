import SwiftUI
import AppKit

@main struct HomeEarApp: App {
    @StateObject private var state = AppState()
    var body: some Scene {
        MenuBarExtra("HomeEar", systemImage: state.microphoneOn ? "waveform" : "waveform.slash") {
            PanelView(state: state)
                .frame(width: 350)
        }
        .menuBarExtraStyle(.window)
        Window("HomeEar Setup", id: "setup") {
            OnboardingView(state: state)
                .frame(minWidth: 540, minHeight: 440)
                .onAppear { bringSetupForward() }
        }
        .defaultSize(width: 560, height: 470)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "waveform.circle.fill").font(.title).foregroundStyle(.teal)
                VStack(alignment: .leading) {
                    Text("HomeEar").font(.headline)
                    Text(state.microphoneOn ? "Listening locally" : "Microphone paused").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(state.microphoneOn ? .green : .gray).frame(width: 9, height: 9)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                StatusRow(icon: "waveform", label: "Speech", value: state.speechState)
                StatusRow(icon: "paperplane", label: "Poke API", value: state.apiState)
                StatusRow(icon: "speaker.wave.2", label: "Voice tool", value: state.ttsState)
                StatusRow(icon: "network", label: "Poke tunnel", value: state.tunnel.state)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("RECENT ACTIVITY").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                Text(state.latestText).font(.subheadline).lineLimit(3)
                if !state.latestDecision.isEmpty { Text(state.latestDecision).font(.caption).foregroundStyle(.secondary) }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
            HStack {
                Button(state.microphoneOn ? "Pause microphone" : "Start microphone") {
                    state.microphoneOn ? state.stop() : state.start()
                }.buttonStyle(.borderedProminent)
                Spacer()
                Button("Settings") {
                    openWindow(id: "setup")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first(where: { $0.title == "HomeEar Setup" })?.makeKeyAndOrderFront(nil)
                    }
                }
            }
            HStack {
                Button("Check updates") { state.updates.check() }
                if state.updates.releaseURL != nil { Button("View release") { state.updates.openRelease() } }
            }.font(.caption)
            Text(state.updates.status).font(.caption2).foregroundStyle(.secondary)
            Divider()
            Button("Quit HomeEar") { NSApplication.shared.terminate(nil) }.font(.caption)
        }.padding(18)
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
