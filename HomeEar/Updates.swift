import Foundation
import AppKit

@MainActor final class UpdateChecker: ObservableObject {
    @Published private(set) var status = "Check for updates"
    @Published private(set) var releaseURL: URL?
    func check() {
        status = "Checking..."
        Task {
            do {
                var request = URLRequest(url: URL(string: "https://api.github.com/repos/Malti2/HomeEar/releases/latest")!)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw UpdateError.unavailable }
                if http.statusCode == 404 { status = "No public release yet"; return }
                guard http.statusCode == 200,
                      let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = record["tag_name"] as? String,
                      let url = record["html_url"] as? String,
                      let release = URL(string: url), release.host == "github.com",
                      release.path.hasPrefix("/Malti2/HomeEar/releases/") else { throw UpdateError.unavailable }
                releaseURL = release
                let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
                status = tag.trimmingCharacters(in: CharacterSet(charactersIn: "v")) == current ? "Up to date (\(tag))" : "Release \(tag) available to review"
            } catch { status = "Could not check releases" }
        }
    }
    func openRelease() { if let releaseURL { NSWorkspace.shared.open(releaseURL) } }
    enum UpdateError: Error { case unavailable }
}
