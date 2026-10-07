import Foundation
import AppKit
import Combine
import Sparkle

/// Sparkle validates signed feeds and archives before installing or relaunching.
/// No quarantine removal, shell installer, or unverified release-asset fallback.
@MainActor final class UpdateChecker: ObservableObject {
    @Published private(set) var status = "Updates from GitHub Releases"
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    private let controller: SPUStandardUpdaterController

    init() {
        // Screenshots and unit tests must not check the network or install updates.
        let capture = CommandLine.arguments.contains("--capture-ui")
        let tests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: nil, userDriverDelegate: nil)
        if !capture && !tests {
            controller.startUpdater()
            controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
            controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        }
    }
    func check() {
        guard canCheckForUpdates else { return }
        status = "Checking signed release feed..."
        controller.checkForUpdates(nil)
    }
    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }
    func openRelease() {
        NSWorkspace.shared.open(URL(string: "https://github.com/Malti2/HomeEar/releases")!)
    }
}
