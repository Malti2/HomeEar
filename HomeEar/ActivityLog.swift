import Foundation
import CryptoKit

enum ActivityOutcome: String {
    case sent, filtered, asked, cancelled, duplicate

    var label: String {
        switch self {
        case .sent: "Sent"
        case .filtered: "Not sent"
        case .asked: "Asked"
        case .cancelled: "Discarded"
        case .duplicate: "Duplicate"
        }
    }
}

/// One thing HomeEar heard and what it did about it.
struct ActivityEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let text: String
    let outcome: ActivityOutcome
    let reason: String
    let source: FilterSource?
}

/// Recent activity of this session. Memory only: nothing here is written to disk.
struct ActivityLog: Equatable {
    static let limit = 50
    private(set) var entries: [ActivityEntry] = []

    mutating func add(_ entry: ActivityEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    mutating func clear() { entries.removeAll() }
}

/// Corrections the user made ("send this anyway", "that wasn't a command"), kept per exact
/// sentence. Only a SHA-256 of the normalised sentence is stored, so the saved data can
/// say "this sentence was corrected" without containing anything anyone said.
struct FilterFeedback: Codable, Equatable {
    enum Verdict: String, Codable { case send, ignore }

    static let limit = 200
    private var order: [String] = []
    private var verdicts: [String: Verdict] = [:]

    var count: Int { order.count }

    static func key(for text: String) -> String {
        let digest = SHA256.hash(data: Data(QuickPhrases.normalize(text).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func verdict(for text: String) -> Verdict? { verdicts[Self.key(for: text)] }

    mutating func record(_ verdict: Verdict, for text: String) {
        guard !QuickPhrases.normalize(text).isEmpty else { return }
        let key = Self.key(for: text)
        order.removeAll { $0 == key }
        order.append(key)
        verdicts[key] = verdict
        while order.count > Self.limit { verdicts[order.removeFirst()] = nil }
    }

    mutating func removeAll() {
        order.removeAll()
        verdicts.removeAll()
    }
}
