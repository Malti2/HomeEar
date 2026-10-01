import Foundation

/// Routes live transcription into wake-word commands and proactive requests.
///
/// Two input paths, one sender:
/// - Wake word ("Hey Poke", fuzzy): explicit invocation. The command in the
///   same utterance — or, for a lone "Hey Poke", the next utterance within
///   `commandWindow` seconds — is forwarded untouched, no filter applied.
/// - Proactive filter: final transcriptions that score as likely commands
///   without a wake word are forwarded when enabled.
///
/// A dedup window suppresses repeats regardless of source: TV repeats,
/// stuttered repeats, and the partial+final double-fire of a single
/// utterance are each sent only once.
@MainActor final class UtteranceRouter {
    struct Config {
        var wakeWordEnabled = true
        var proactiveEnabled = true
        var strictFilter = true
        /// How long to wait for the command after a lone "Hey Poke".
        var commandWindow: TimeInterval = 7
        /// Identical requests within this window are sent only once.
        var duplicateWindow: TimeInterval = 60
        var maxHistory = 10
    }

    var config = Config()

    /// (text, source) — the app forwards this to Poke.
    var onDeliver: ((String, FilterSource) -> Void)?
    /// Human-readable routing decisions, shown in the menu-bar panel.
    var onDecision: ((String) -> Void)?
    /// True while waiting for the command after a lone "Hey Poke".
    var onCommandModeChanged: ((Bool) -> Void)?

    private enum Mode { case idle, awaitingCommand(deadline: Date) }
    private var mode: Mode = .idle
    private var deliveries: [(key: String, at: Date)] = []

    func receive(_ text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Expire a stale command-capture window.
        if case .awaitingCommand(let deadline) = mode, Date() > deadline {
            setMode(.idle)
            onDecision?("Wake word timed out — listening normally")
        }

        // 1. Wake word, on partials and finals alike (partials arm the
        //    capture; only finals deliver, so we act on stable text).
        if config.wakeWordEnabled, let match = WakeWordDetector.detect(in: trimmed) {
            handleWakeWord(match, isFinal: isFinal)
            return
        }

        // 2. Command capture after a lone "Hey Poke": finals go straight
        //    through, no proactive filter — the user explicitly invoked us.
        if isAwaiting(mode) {
            if isFinal, isSubstantial(trimmed) {
                setMode(.idle)
                deliver(trimmed, source: .wakeWord)
            }
            return
        }

        // 3. Proactive path: finals only (partials are too unstable to judge).
        guard isFinal else { return }
        guard config.proactiveEnabled else { return }
        // A leftover "hey poke" (wake word disabled, said out of habit) is
        // stripped so Poke gets the command, not the trigger phrase.
        let command = WakeWordDetector.stripLeadingWakeWord(from: trimmed) ?? trimmed
        switch RequestFilter.checkProactive(command, strict: config.strictFilter) {
        case .accept(let source, let reason):
            onDecision?("\(source.rawValue): \(reason)")
            deliver(command, source: source)
        case .reject(let reason):
            onDecision?(reason)
        }
    }

    /// Call when the microphone stops so a pending capture window can't leak
    /// into the next session.
    func reset() {
        setMode(.idle)
    }

    // MARK: - private

    private func handleWakeWord(_ match: WakeWordDetector.Match, isFinal: Bool) {
        if isSubstantial(match.commandText) {
            // "Hey Poke, mach das Licht an" — the command is right there.
            if isFinal {
                setMode(.idle)
                onDecision?("Wake word: command captured")
                deliver(match.commandText, source: .wakeWord)
            } else {
                armCapture()
            }
        } else {
            // Lone "Hey Poke" — capture the next utterance.
            armCapture()
            onDecision?("Wake word heard — listening for command…")
        }
    }

    private func armCapture() {
        let deadline = Date().addingTimeInterval(config.commandWindow)
        setMode(.awaitingCommand(deadline: deadline))
        // In case no further speech arrives, the window must still expire.
        let nanos = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            self?.expireCommandMode(deadline: deadline)
        }
    }

    private func expireCommandMode(deadline: Date) {
        if case .awaitingCommand(let current) = mode, current == deadline {
            setMode(.idle)
            onDecision?("Wake word timed out — listening normally")
        }
    }

    private func isAwaiting(_ mode: Mode) -> Bool {
        if case .awaitingCommand = mode { return true }
        return false
    }

    private func setMode(_ mode: Mode) {
        let changed = isAwaiting(self.mode) != isAwaiting(mode)
        self.mode = mode
        if changed { onCommandModeChanged?(isAwaiting(mode)) }
    }

    private func isSubstantial(_ text: String) -> Bool {
        // Deliberately lenient: the user explicitly invoked us, so even a
        // single word ("Hey Poke, stopp") is a command worth forwarding.
        let words = text.split(whereSeparator: \.isWhitespace)
        return words.count >= 1 && text.count >= 3
    }

    private func deliver(_ text: String, source: FilterSource) {
        let key = normalizedKey(text)
        let now = Date()
        deliveries.removeAll { now.timeIntervalSince($0.at) > config.duplicateWindow }
        guard !deliveries.contains(where: { $0.key == key }) else {
            onDecision?("Duplicate suppressed (\(source.rawValue.lowercased()))")
            return
        }
        deliveries.append((key, now))
        if deliveries.count > config.maxHistory {
            deliveries.removeFirst(deliveries.count - config.maxHistory)
        }
        onDeliver?(text, source)
    }

    private func normalizedKey(_ text: String) -> String {
        let lower = text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
