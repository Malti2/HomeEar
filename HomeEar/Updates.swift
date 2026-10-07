import Foundation
import AppKit
import Combine
import Sparkle

enum UpdateChannel: String, CaseIterable { case stable, beta }
struct GitHubUpdateRelease: Decodable {
    struct Asset: Decodable { let name: String; let browser_download_url: String }
    let draft: Bool
    let prerelease: Bool
    let tag_name: String
    let assets: [Asset]
}
enum ReleaseDiscovery {
    enum Failure: LocalizedError {
        case missingFeed, invalidFeed, unavailable(Int)
        var errorDescription: String? {
            switch self {
            case .missingFeed: "Release is missing its signed update feed."
            case .invalidFeed: "Release has an invalid update feed address."
            case .unavailable(let code): "GitHub release lookup failed (HTTP \(code))."
            }
        }
    }
    static func feed(from data: Data, channel: UpdateChannel) throws -> URL? {
        let releases = try JSONDecoder().decode([GitHubUpdateRelease].self, from: data)
        guard let release = releases.first(where: { !$0.draft && $0.prerelease == (channel == .beta) }) else { return nil }
        guard let asset = release.assets.first(where: { $0.name == "appcast.xml" }) else { throw Failure.missingFeed }
        guard let url = URL(string: asset.browser_download_url), url.scheme == "https", url.host == "github.com",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/Malti2/HomeEar/releases/download/"), url.lastPathComponent == "appcast.xml" else { throw Failure.invalidFeed }
        return url
    }
}

/// GitHub chooses a channel; Sparkle still verifies the signed feed and archive.
@MainActor final class UpdateChecker: NSObject, ObservableObject, @preconcurrency SPUUpdaterDelegate {
    @Published private(set) var status = "Choose a channel and check for updates"
    @Published private(set) var canCheckForUpdates = true
    @Published private(set) var automaticallyChecks = UserDefaults.standard.bool(forKey: "HomeEarAutomaticUpdates")
    @Published private(set) var channel = UpdateChannel(rawValue: UserDefaults.standard.string(forKey: "HomeEarUpdateChannel") ?? "stable") ?? .stable
    private var resolvedFeed: URL?
    private var timer: Timer?
    private var checking = false
    private var generation = 0
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false,
        updaterDelegate: self, userDriverDelegate: nil)
    private var started = false
    private let inactive = CommandLine.arguments.contains("--capture-ui") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    override init() {
        super.init()
        if !inactive { configureTimer() }
    }
    func setChannel(_ value: UpdateChannel) {
        guard !checking else { return }
        channel = value
        generation += 1
        resolvedFeed = nil
        status = "\(value == .stable ? "Stable" : "Beta") selected; check for updates"
        UserDefaults.standard.set(value.rawValue, forKey: "HomeEarUpdateChannel")
    }
    func check() {
        guard !checking, !inactive else { return }
        let selected = channel
        let currentGeneration = generation
        checking = true
        canCheckForUpdates = false
        status = "Checking \(selected.rawValue) releases..."
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/Malti2/HomeEar/releases?per_page=100")!)
                request.timeoutInterval = 15
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                guard http.statusCode == 200 else { throw ReleaseDiscovery.Failure.unavailable(http.statusCode) }
                guard currentGeneration == generation else { finish(); return }
                guard let feed = try ReleaseDiscovery.feed(from: data, channel: selected) else {
                    status = "No \(selected.rawValue) release is available yet"
                    finish()
                    return
                }
                resolvedFeed = feed
                if !started {
                    controller.startUpdater()
                    started = true
                }
                guard controller.updater.canCheckForUpdates else {
                    status = "Updater is not ready; try again later"
                    finish()
                    return
                }
                status = "Verifying \(selected.rawValue) update information..."
                controller.checkForUpdates(nil)
            } catch {
                status = "Update check failed: \(error.localizedDescription)"
                finish()
            }
        }
    }
    func feedURLString(for updater: SPUUpdater) -> String? { resolvedFeed?.absoluteString }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        status = "No newer \(channel.rawValue) version is available"
    }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        status = "A \(channel.rawValue) update is available; review before installing"
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { status = "Update check failed: \(error.localizedDescription)" }
        finish()
    }
    private func finish() { checking = false; canCheckForUpdates = true }
    func setAutomaticChecks(_ enabled: Bool) {
        automaticallyChecks = enabled
        UserDefaults.standard.set(enabled, forKey: "HomeEarAutomaticUpdates")
        if !inactive { configureTimer() }
    }
    private func configureTimer() {
        timer?.invalidate()
        guard automaticallyChecks else { return }
        // Keep Sparkle's own scheduling off so every check resolves the selected channel first.
        timer = Timer.scheduledTimer(withTimeInterval: 86400, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
    }
    func openRelease() { NSWorkspace.shared.open(URL(string: "https://github.com/Malti2/HomeEar/releases")!) }
}
