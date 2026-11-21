import Foundation

/// Tells when a microphone that has just been switched on starts carrying real sound.
///
/// A built-in MacBook microphone answers within about 40 ms of being started, but what it sends
/// for the next 0.17 s is not the room: a click that dies away within 50 ms, then digital silence,
/// while its signal processing starts up. Only after that is it hearing. (Measured at 10 ms
/// resolution: about -62, -70, -80, -88, -95, -105 dB … down to -180, then -115, -88, -72, -62.)
///
/// The gate watches the level of the incoming audio in 10 ms slices of 16 kHz samples and opens
/// when sound is really there:
///
/// - sound still present 50 to 70 ms in, by which time a start-up click has died: this microphone
///   has no start-up silence (most USB ones, or one that another app already has open);
/// - later, two slices in a row above the silence that do not die away: the microphone has come alive;
/// - otherwise after 0.4 s, so it can never stay shut.
struct StartupGate {
    private(set) var isOpen = false
    /// Samples that arrived before real sound began.
    private(set) var deadSamples = 0
    /// The gate opened because the wait ran out, not because sound was found (a muted microphone).
    private(set) var gaveUp = false

    private var sliceSum: Float = 0
    private var sliceFill = 0
    private var slices = 0
    private var levels: [Float] = []

    static let sliceSamples = 160
    /// Slices below this (dBFS) are start-up silence or the tail of the click, not a room.
    static let soundLevel: Float = -90
    /// A start-up click is below this by its fifth slice; real sound from the start is not.
    static let presentLevel: Float = -85
    /// By this slice (70 ms) a start-up click has died away.
    static let clickSlices = 7
    static let longestWaitSlices = 40

    /// A gate for a stream that is already known to be carrying sound.
    static var open: StartupGate {
        var gate = StartupGate()
        gate.isOpen = true
        return gate
    }

    /// Feeds 16 kHz samples. Returns true on the call during which the gate opens.
    mutating func feed(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard !isOpen else { return false }
        for sample in samples {
            sliceSum += sample * sample
            sliceFill += 1
            guard sliceFill == StartupGate.sliceSamples else { continue }
            let rms = (sliceSum / Float(StartupGate.sliceSamples)).squareRoot()
            let level: Float = rms > 0 ? 20 * log10(rms) : -200
            sliceSum = 0
            sliceFill = 0
            slices += 1
            if let dead = opening(at: level) {
                isOpen = true
                deadSamples = dead
                return true
            }
        }
        return false
    }

    /// Decides whether this slice opens the gate; if so, returns how many samples before it were dead.
    private mutating func opening(at level: Float) -> Int? {
        levels.append(level)
        let count = StartupGate.clickSlices
        if slices < count { return nil }
        if slices == count {
            // Still clearly audible after the time a click needs to die: it was sound from the first sample.
            return levels.suffix(3).allSatisfy { $0 > StartupGate.presentLevel } ? 0 : nil
        }
        // After the click: two slices in a row that are above the silence and not dying away.
        let before = levels[levels.count - 2]
        if before > StartupGate.soundLevel, level > StartupGate.soundLevel, level > before - 3 {
            return (slices - 2) * StartupGate.sliceSamples
        }
        guard slices >= StartupGate.longestWaitSlices else { return nil }
        gaveUp = true
        return (slices - 1) * StartupGate.sliceSamples
    }
}

/// The most recent audio of a microphone that is kept open, so a dictation can include the
/// fraction of a second before its key went down.
struct SampleRing {
    private var storage: [Float]
    private var next = 0
    private var filled = 0

    init(capacity: Int) {
        storage = [Float](repeating: 0, count: max(1, capacity))
    }

    mutating func write(_ samples: UnsafeBufferPointer<Float>) {
        for sample in samples {
            storage[next] = sample
            next = (next + 1) % storage.count
        }
        filled = min(storage.count, filled + samples.count)
    }

    /// The newest `count` samples, oldest first.
    func latest(_ count: Int) -> [Float] {
        let wanted = min(count, filled)
        guard wanted > 0 else { return [] }
        var result = [Float]()
        result.reserveCapacity(wanted)
        var index = (next - wanted + storage.count * 2) % storage.count
        for _ in 0..<wanted {
            result.append(storage[index])
            index = (index + 1) % storage.count
        }
        return result
    }

    mutating func clear() {
        filled = 0
        next = 0
    }
}
