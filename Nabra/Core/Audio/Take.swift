import Accelerate
import Foundation

/// Monotonic time in nanoseconds (does not advance while the Mac sleeps). Matches Core Audio host time.
enum Uptime {
    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Milliseconds from `start` to `end`; negative when `end` is earlier.
    static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000 : -Double(start - end) / 1_000_000
    }
}

/// The audio of one dictation: 16 kHz mono samples that grow while the microphone is open.
///
/// Every press of the dictation key gets its own take. A take that is still being transcribed keeps
/// its samples, so the next recording starting can never disturb it.
final class Take: SampleSource {
    /// When things happened, as `Uptime` values (0 = not yet). For the log.
    struct Timing {
        /// The hardware was told to start (or was found already running).
        var captureStarted: UInt64 = 0
        /// The first audio reached the app.
        var firstAudio: UInt64 = 0
        /// The moment that first audio was picked up by the microphone.
        var firstSample: UInt64 = 0
        /// The microphone started carrying real sound (after its start-up silence).
        var soundStarted: UInt64 = 0
        /// Which capture path was used.
        var backend = ""
        /// Samples taken from before the take began (microphone kept open).
        var prefilled = 0
        /// No sound was found within the wait: the take was let through anyway.
        var stillSilent = false
    }

    let id: Int
    /// When capture was asked for.
    let requestedAt: UInt64

    private let lock = NSLock()
    private var samples: [Float] = []
    private var sealed = false
    private var times = Timing()
    private var peak: Float = 0

    init(id: Int, requestedAt: UInt64 = Uptime.now) {
        self.id = id
        self.requestedAt = requestedAt
        samples.reserveCapacity(SpeechEngine.sampleRate * 8)
    }

    // MARK: SampleSource

    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    func copySamples(in range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let lower = max(0, min(range.lowerBound, samples.count))
        let upper = max(lower, min(range.upperBound, samples.count))
        return Array(samples[lower..<upper])
    }

    /// Everything recorded so far.
    func allSamples() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    // MARK: State

    var timing: Timing {
        lock.lock(); defer { lock.unlock() }
        return times
    }

    /// True once the microphone is really being heard.
    var hasSound: Bool {
        lock.lock(); defer { lock.unlock() }
        return times.soundStarted != 0
    }

    var isSealed: Bool {
        lock.lock(); defer { lock.unlock() }
        return sealed
    }

    /// True when audio arrived but every sample of it was zero. A working microphone always picks up
    /// some noise, so this means it is muted or switched off (a MacBook's own microphone is
    /// disconnected while the lid is closed).
    var isDigitalSilence: Bool {
        lock.lock(); defer { lock.unlock() }
        return samples.count > times.prefilled && peak < 1e-7
    }

    // MARK: Written by the recorder

    func noteCaptureStarted(backend: String, at time: UInt64 = Uptime.now) {
        lock.lock()
        // A restart mid-recording keeps the original start time.
        if times.captureStarted == 0 { times.captureStarted = time }
        times.backend = backend
        lock.unlock()
    }

    /// Puts audio from just before the take began at its start. Only valid before anything is appended.
    func prefill(_ earlier: [Float]) {
        lock.lock(); defer { lock.unlock() }
        guard samples.isEmpty, !sealed, !earlier.isEmpty else { return }
        samples.append(contentsOf: earlier)
        times.prefilled = earlier.count
    }

    /// Adds samples. `capturedAt` is when the first of them was picked up, if known.
    func append(_ buffer: UnsafeBufferPointer<Float>, capturedAt: UInt64 = 0) {
        guard buffer.count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !sealed else { return }
        if times.firstAudio == 0 {
            times.firstAudio = Uptime.now
            times.firstSample = capturedAt != 0 ? capturedAt : times.firstAudio
        }
        samples.append(contentsOf: buffer)
        if let base = buffer.baseAddress {
            var loudest: Float = 0
            vDSP_maxmgv(base, 1, &loudest, vDSP_Length(buffer.count))
            peak = max(peak, loudest)
        }
    }

    /// Records that real sound is arriving (or, with `stillSilent`, that waiting for it was given up).
    /// Returns true the first time.
    func markSoundStarted(at time: UInt64 = Uptime.now, stillSilent: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard times.soundStarted == 0 else { return false }
        times.soundStarted = time
        times.stillSilent = stillSilent
        return true
    }

    /// No more audio will be added.
    func seal() {
        lock.lock()
        sealed = true
        lock.unlock()
    }
}
