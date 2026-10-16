import Foundation

/// How loud the last stretch of speech was compared to the room.
struct AudioFeatures: Equatable {
    /// Speech level (90th percentile, dBFS) minus the rolling noise floor.
    let snr: Double
}

/// Whether an utterance sounds like it was said close to the microphone.
enum AudioCue: Equatable {
    case normal
    /// Clearly quieter than the user's own voice: TV, radio, another room.
    case far
}

/// Learns how loud the user sounds when they deliberately say "Hey Poke",
/// and judges later utterances against that. Until a reference exists, a
/// generic prior for a laptop microphone is used.
struct VoiceProfile: Equatable {
    static let prior = 22.0
    /// Distance below the reference at which speech counts as far away.
    static let farMargin = 12.0

    var referenceSNR: Double?

    func cue(forSNR snr: Double) -> AudioCue {
        snr - (referenceSNR ?? Self.prior) <= -Self.farMargin ? .far : .normal
    }

    /// Slow moving average, so one shouted or whispered command doesn't skew it.
    mutating func learn(snr: Double) {
        guard snr > 0 else { return }
        referenceSNR = referenceSNR.map { $0 * 0.8 + snr * 0.2 } ?? snr
    }
}

/// Tracks microphone loudness from the audio tap. Only levels are kept, never
/// audio: a few seconds of dB values and a slowly moving noise floor.
/// Written from the realtime audio thread, read from the main actor.
final class AudioLevelTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [(time: TimeInterval, db: Float)] = []
    private var noiseFloor: Float?
    private let window: TimeInterval

    init(window: TimeInterval = 3) { self.window = window }

    func record(db: Float, at time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        samples.append((time, db))
        while let first = samples.first, time - first.time > window { samples.removeFirst() }
        if let current = noiseFloor {
            // Drops fast, rises slowly: speech must not drag the floor up.
            noiseFloor = current + (db < current ? 0.3 : 0.0005) * (db - current)
        } else {
            noiseFloor = db
        }
    }

    func snapshot(at now: TimeInterval) -> AudioFeatures? {
        lock.lock()
        defer { lock.unlock() }
        let recent = samples.filter { now - $0.time <= window }.map { $0.db }.sorted()
        guard recent.count >= 10, let noiseFloor else { return nil }
        let loud = recent[min(recent.count - 1, Int(Double(recent.count) * 0.9))]
        return AudioFeatures(snr: Double(loud - noiseFloor))
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        samples.removeAll()
        noiseFloor = nil
    }

    /// Level of one audio buffer in dBFS, or nil for formats we can't read.
    static func decibels(of buffer: UnsafeBufferPointer<Float>) -> Float? {
        guard !buffer.isEmpty else { return nil }
        var sum: Float = 0
        for value in buffer { sum += value * value }
        let rms = (sum / Float(buffer.count)).squareRoot()
        return 20 * log10(max(rms, 1e-5))
    }
}
