import Foundation

/// A request the router isn't sure about and has asked the user to confirm.
struct PendingRequest: Equatable {
    let text: String
    let source: FilterSource
    let reason: String
}

/// Routes live transcription into wake-word commands, follow-ups and proactive requests.
///
/// Input paths, one sender:
/// - Wake word ("Hey Poke", fuzzy): explicit invocation. The command in the
///   same utterance — or, for a lone "Hey Poke", the next utterance within
///   `commandWindow` seconds — is forwarded untouched, no filter applied.
/// - Follow-up window: after HomeEar finished speaking a reply, the next few
///   seconds accept a short answer or "und im Flur auch" without a wake word.
/// - Proactive filter: final transcriptions that score as likely commands
///   without a wake word are forwarded when enabled. Borderline ones are not
///   guessed at: the router asks ("Meintest du …?") and waits for yes or no.
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
        /// User-defined smart-home words that count as entities in the proactive filter.
        var extraEntities: Set<String> = []
        /// Names of people at home; a request addressed to one is not for HomeEar.
        var addressees: Set<String> = []
        /// Judge how far from the microphone speech sounded (proactive path only).
        var audioCuesEnabled = true
        /// Ask "did you mean …?" for borderline requests instead of dropping them.
        var askWhenUnsure = true
        /// Accept short follow-ups after a spoken reply.
        var followUpEnabled = true
        /// Total time a question stays open; the app restarts it once the question was spoken.
        var confirmationWindow: TimeInterval = 15
        var confirmationAnswerWindow: TimeInterval = 8
        /// The same sentence is asked about at most once in this time.
        var askCooldown: TimeInterval = 60
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    var config = Config()
    /// Learned from deliberate "Hey Poke" commands; persisted by the app.
    var voiceProfile = VoiceProfile()
    var onVoiceReferenceChanged: ((Double) -> Void)?

    /// (text, source) — the app forwards this to the backend.
    var onDeliver: ((String, FilterSource) -> Void)?
    /// Human-readable routing decisions, shown in the menu-bar panel.
    var onDecision: ((String) -> Void)?
    /// True while the router is waiting for speech without a wake word
    /// (command after a lone "Hey Poke", follow-up, or an answer).
    var onCommandModeChanged: ((Bool) -> Void)?
    /// The router wants the user to confirm this request; the app asks out loud.
    var onAskBack: ((PendingRequest) -> Void)?
    /// The open question changed (nil once answered, discarded or expired).
    var onPendingChanged: ((PendingRequest?) -> Void)?

    private enum Mode {
        case idle
        case awaitingCommand(deadline: Date)
        case followUp(deadline: Date, expectsAnswer: Bool)
        case awaitingConfirmation(PendingRequest, deadline: Date)
    }
    private var mode: Mode = .idle
    private var deliveries: [(key: String, at: Date)] = []
    private var asked: [(key: String, at: Date)] = []

    func receive(_ text: String, isFinal: Bool, audio: AudioFeatures? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Expire a stale window.
        if let deadline = windowEnd(of: mode), Date() > deadline { expire() }

        // 1. Wake word, on partials and finals alike (partials arm the
        //    capture; only finals deliver, so we act on stable text).
        if config.wakeWordEnabled, let match = WakeWordDetector.detect(in: trimmed) {
            handleWakeWord(match, isFinal: isFinal, audio: audio)
            return
        }

        // 2. Open windows. Finals only: partials are too unstable to judge.
        switch mode {
        case .awaitingCommand:
            // Command capture after a lone "Hey Poke": finals go straight
            // through, no proactive filter — the user explicitly invoked us.
            if isFinal, isCancel(trimmed) {
                setMode(.idle)
                onDecision?("Wake word cancelled")
            } else if isFinal, isSubstantial(trimmed) {
                setMode(.idle)
                learn(audio)
                deliver(trimmed, source: .wakeWord)
            }
            return
        case .awaitingConfirmation(let pending, _):
            guard isFinal else { return }
            switch Self.answer(to: trimmed) {
            case .yes:
                setMode(.idle)
                onDecision?("Confirmed — sending")
                deliver(pending.text, source: pending.source)
            case .no:
                setMode(.idle)
                onDecision?("Discarded")
            case nil:
                break // not an answer; keep waiting until the window closes
            }
            return
        case .followUp(_, let expectsAnswer):
            if isFinal, handleFollowUp(trimmed, expectsAnswer: expectsAnswer, audio: audio) { return }
        case .idle:
            break
        }

        // 3. Proactive path.
        guard isFinal else { return }
        guard config.proactiveEnabled else { return }
        // A leftover "hey poke" (wake word disabled, said out of habit) is
        // stripped so Poke gets the command, not the trigger phrase.
        let command = WakeWordDetector.stripLeadingWakeWord(from: trimmed) ?? trimmed
        let cue: AudioCue = config.audioCuesEnabled ? audio.map { voiceProfile.cue(forSNR: $0.snr) } ?? .normal : .normal
        switch RequestFilter.checkProactive(command, strict: config.strictFilter, extra: config.extraEntities,
                                              addressees: config.addressees, audio: cue) {
        case .accept(let source, let reason):
            onDecision?("\(source.rawValue): \(reason)")
            deliver(command, source: source)
        case .uncertain(let reason):
            if config.askWhenUnsure, cue != .far, canAsk(command) {
                ask(PendingRequest(text: command, source: .proactive, reason: reason))
            } else {
                onDecision?("Background speech filtered (\(reason))")
            }
        case .reject(let reason):
            onDecision?(reason)
        }
    }

    /// Opens the follow-up window. Call when HomeEar has finished speaking a reply.
    /// While a question is open, this only restarts its answer window.
    func openFollowUp(window: TimeInterval = 8, expectsAnswer: Bool) {
        if case .awaitingConfirmation(let pending, _) = mode {
            let deadline = Date().addingTimeInterval(config.confirmationAnswerWindow)
            setMode(.awaitingConfirmation(pending, deadline: deadline))
            armTimer(for: deadline)
            return
        }
        guard config.followUpEnabled else { return }
        if case .awaitingCommand = mode { return }
        let deadline = Date().addingTimeInterval(window)
        setMode(.followUp(deadline: deadline, expectsAnswer: expectsAnswer))
        armTimer(for: deadline)
        if expectsAnswer { onDecision?("Waiting for your answer…") }
    }

    /// Panel button: send the request that was asked about.
    func confirmPending() {
        guard case .awaitingConfirmation(let pending, _) = mode else { return }
        setMode(.idle)
        onDecision?("Confirmed — sending")
        deliver(pending.text, source: pending.source)
    }

    /// Panel button: drop the request that was asked about.
    func discardPending() {
        guard case .awaitingConfirmation = mode else { return }
        setMode(.idle)
        onDecision?("Discarded")
    }

    /// Call when the microphone stops so a pending window can't leak
    /// into the next session.
    func reset() {
        setMode(.idle)
    }

    // MARK: - private

    private func handleWakeWord(_ match: WakeWordDetector.Match, isFinal: Bool, audio: AudioFeatures?) {
        if isCancel(match.commandText) {
            // "Hey Poke, abbrechen" — never forward the cancel word itself.
            if isFinal {
                setMode(.idle)
                onDecision?("Wake word cancelled")
            }
        } else if isSubstantial(match.commandText) {
            // "Hey Poke, mach das Licht an" — the command is right there.
            if isFinal {
                setMode(.idle)
                onDecision?("Wake word: command captured")
                learn(audio)
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

    /// Returns true when the utterance was consumed by the follow-up window.
    private func handleFollowUp(_ text: String, expectsAnswer: Bool, audio: AudioFeatures?) -> Bool {
        if isCancel(text) {
            setMode(.idle)
            onDecision?("Follow-up cancelled")
            return true
        }
        // Distant speech never answers; let it fall through to the normal filter.
        if config.audioCuesEnabled, let audio, voiceProfile.cue(forSNR: audio.snr) == .far { return false }
        let accepted = expectsAnswer
            ? text.count >= 2
            : RequestFilter.looksLikeFollowUp(text, extra: config.extraEntities)
        guard accepted else { return false }
        setMode(.idle)
        onDecision?("Follow-up: command captured")
        deliver(text, source: .followUp)
        return true
    }

    private func ask(_ pending: PendingRequest) {
        asked.append((normalizedKey(pending.text), Date()))
        let deadline = Date().addingTimeInterval(config.confirmationWindow)
        setMode(.awaitingConfirmation(pending, deadline: deadline))
        armTimer(for: deadline)
        onDecision?("Not sure — asking: \(pending.reason)")
        onAskBack?(pending)
    }

    private func canAsk(_ text: String) -> Bool {
        let now = Date()
        asked.removeAll { now.timeIntervalSince($0.at) > config.askCooldown }
        return !asked.contains { $0.key == normalizedKey(text) }
    }

    private func armCapture() {
        let deadline = Date().addingTimeInterval(config.commandWindow)
        setMode(.awaitingCommand(deadline: deadline))
        armTimer(for: deadline)
    }

    /// In case no further speech arrives, the window must still expire.
    private func armTimer(for deadline: Date) {
        let nanos = UInt64(max(0, deadline.timeIntervalSinceNow) * 1_000_000_000)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard let self, self.windowEnd(of: self.mode) == deadline else { return }
            self.expire()
        }
    }

    private func expire() {
        let message: String
        switch mode {
        case .awaitingCommand: message = "Wake word timed out — listening normally"
        case .followUp: message = "Follow-up window closed"
        case .awaitingConfirmation: message = "No answer — request discarded"
        case .idle: return
        }
        setMode(.idle)
        onDecision?(message)
    }

    private func deadline(of mode: Mode) -> Date? {
        switch mode {
        case .idle: nil
        case .awaitingCommand(let deadline): deadline
        case .followUp(let deadline, _): deadline
        case .awaitingConfirmation(_, let deadline): deadline
        }
    }

    private func isActive(_ mode: Mode) -> Bool {
        if case .idle = mode { return false }
        return true
    }

    private func pending(of mode: Mode) -> PendingRequest? {
        if case .awaitingConfirmation(let pending, _) = mode { return pending }
        return nil
    }

    private func setMode(_ new: Mode) {
        let wasActive = isActive(mode)
        let oldPending = pending(of: mode)
        mode = new
        if wasActive != isActive(new) { onCommandModeChanged?(isActive(new)) }
        let newPending = pending(of: new)
        if oldPending != newPending { onPendingChanged?(newPending) }
    }

    private func learn(_ audio: AudioFeatures?) {
        guard config.audioCuesEnabled, let audio, audio.snr > 0 else { return }
        voiceProfile.learn(snr: audio.snr)
        if let reference = voiceProfile.referenceSNR { onVoiceReferenceChanged?(reference) }
    }

    private static let cancelPhrases: Set<String> = [
        "abbrechen", "vergiss es", "vergiss das", "schon gut", "lass gut sein",
        "cancel", "never mind", "nevermind", "forget it",
    ]

    private func isCancel(_ text: String) -> Bool {
        Self.cancelPhrases.contains(normalizedKey(text))
    }

    private enum Answer { case yes, no }

    private static let yesWords: Set<String> = [
        "ja", "jo", "jep", "jap", "klar", "genau", "stimmt", "richtig", "ok", "okay",
        "gerne", "bitte", "mach das", "yes", "yeah", "yep", "sure", "do it",
    ]
    private static let noWords: Set<String> = [
        "nein", "nee", "nö", "nicht", "stopp", "stop", "lass", "no", "nope",
    ]

    private static func answer(to text: String) -> Answer? {
        let key = text.lowercased(with: posix)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        if yesWords.contains(key) { return .yes }
        if noWords.contains(key) || cancelPhrases.contains(key) { return .no }
        return nil
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
        let lower = text.lowercased(with: Self.posix)
        return lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }
}
