import Foundation
import AVFoundation
import Speech

@MainActor final class AppleSpeechEngine {
    enum Failure: LocalizedError {
        case microphone, recognition, locale, model, format
        var errorDescription: String? {
            switch self {
            case .microphone: "Microphone access denied. Enable HomeEar in System Settings > Privacy & Security > Microphone."
            case .recognition: "Speech recognition access denied. Enable it in System Settings > Privacy & Security."
            case .locale: "This speech language is not available on this Mac."
            case .model: "The speech model could not be installed. Check your connection and retry."
            case .format: "The microphone format could not be prepared."
            }
        }
    }
    weak var state: AppState?
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    init(state: AppState) { self.state = state }

    func start(language: String) async throws {
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw Failure.microphone }
        let authorized = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard authorized else { throw Failure.recognition }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else { throw Failure.locale }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [])
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
                    guard result.isFinal else { continue }
                    let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { self?.state?.receive(text) }
                }
            } catch { self?.state?.speechState = "Transcription stopped: \(error.localizedDescription)" }
        }
        do {
            try await analyzer.start(inputSequence: stream)
            let input = engine.inputNode
            let source = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: source, to: target) else { throw Failure.format }
            input.installTap(onBus: 0, bufferSize: 4096, format: source) { buffer, _ in
                let ratio = target.sampleRate / source.sampleRate
                let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 64
                guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
                let once = OneShotBuffer(buffer)
                var error: NSError?
                let status = converter.convert(to: output, error: &error) { _, status in
                    guard let next = once.take() else { status.pointee = .noDataNow; return nil }
                    status.pointee = .haveData
                    return next
                }
                if status != .error, output.frameLength > 0 { builder.yield(AnalyzerInput(buffer: output)) }
            }
            engine.prepare()
            try engine.start()
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
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
