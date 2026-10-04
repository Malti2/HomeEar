import Foundation
import AVFoundation
import Speech

@MainActor final class AppleSpeechEngine {
    enum Failure: LocalizedError {
        case microphone, recognition, locale, model, format, inputUnavailable
        var errorDescription: String? {
            switch self {
            case .microphone: "Microphone access denied. Enable HomeEar in System Settings > Privacy & Security > Microphone."
            case .recognition: "Speech recognition access denied. Enable it in System Settings > Privacy & Security."
            case .locale: "This speech language is not available on this Mac."
            case .model: "The speech model could not be installed. Check your connection and retry."
            case .format: "The microphone format could not be prepared."
            case .inputUnavailable: "No usable microphone input is available. Check your audio input device in System Settings and try again."
            }
        }
    }
    weak var state: AppState?
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var tapInstalled = false
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(state: AppState) { self.state = state }

    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                // TCC invokes this completion on a background queue. Resume only
                // the Sendable continuation here; do not touch MainActor state.
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func start(language: String) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphone }
        let authorized = await Self.requestSpeechAuthorization()
        guard authorized else { throw Failure.recognition }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { throw Failure.locale }
        // A smaller recognition context favors live command responsiveness.
        // Final results still gate delivery; volatile text never controls Poke.
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                state?.speechState = "Installing speech model..."
                try await request.downloadAndInstall()
            }
        } catch { throw Failure.model }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw Failure.format }
        let (stream, builder) = AsyncStream<AnalyzerInput>.makeStream()
        continuation = builder
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    // Partials arm the wake-word detector for instant reaction;
                    // only finals are judged by the proactive filter or delivered.
                    if !text.isEmpty { self?.state?.receive(text, isFinal: result.isFinal) }
                }
            } catch { self?.state?.speechState = "Transcription stopped: \(error.localizedDescription)" }
        }
        do {
            state?.speechState = "Preparing speech model..."
            try await analyzer.prepareToAnalyze(in: target)
            try await analyzer.start(inputSequence: stream)
            let input = engine.inputNode
            let source = input.outputFormat(forBus: 0)
            guard source.channelCount > 0, source.sampleRate > 0,
                  target.channelCount > 0, target.sampleRate > 0 else { throw Failure.inputUnavailable }
            guard let converter = AVAudioConverter(from: source, to: target) else { throw Failure.format }
            // The callback must be formed outside AppleSpeechEngine's MainActor
            // isolation: CoreAudio invokes it on its realtime service queue.
            let sink = AudioTapSink(converter: converter, target: target, continuation: builder)
            sink.install(on: input, format: source)
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        continuation?.finish()
        continuation = nil
        let ending = analyzer
        Task { try? await ending?.finalizeAndFinishThroughEndOfInput() }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
    }
}

private final class OneShotBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AVAudioPCMBuffer?
    init(_ value: AVAudioPCMBuffer) { self.value = value }
    func take() -> AVAudioPCMBuffer? {
        lock.lock()
        defer { lock.unlock() }
        let next = value
        value = nil
        return next
    }
}

// This object has no actor isolation. CoreAudio owns its tap invocation thread;
// it never reads or writes AppleSpeechEngine or AppState. Its converter is used
// only by the installed tap, and the stream continuation is thread-safe.
private final class AudioTapSink: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let continuation: AsyncStream<AnalyzerInput>.Continuation

    init(converter: AVAudioConverter, target: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.converter = converter
        self.target = target
        self.continuation = continuation
    }

    func install(on input: AVAudioInputNode, format source: AVAudioFormat) {
        // Request smaller audio batches: about 21 ms at a 48 kHz input.
        // CoreAudio may supply a different actual buffer size.
        input.installTap(onBus: 0, bufferSize: 1024, format: source) { [self] buffer, _ in
            consume(buffer, sourceRate: source.sampleRate)
        }
    }

    private func consume(_ buffer: AVAudioPCMBuffer, sourceRate: Double) {
        let ratio = target.sampleRate / sourceRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        let once = OneShotBuffer(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            guard let next = once.take() else { status.pointee = .noDataNow; return nil }
            status.pointee = .haveData
            return next
        }
        if status != .error, output.frameLength > 0 { continuation.yield(AnalyzerInput(buffer: output)) }
    }
}
