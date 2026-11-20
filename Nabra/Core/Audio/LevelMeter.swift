import Accelerate
import Foundation

/// Keeps a short history of input loudness (one value per 20 ms) for the waveform.
/// Written from the audio thread, read from the UI.
final class LevelMeter {
    static let sliceSamples = 320
    static let slicesPerSecond = Double(SpeechEngine.sampleRate) / Double(sliceSamples)
    private static let capacity = 512

    private var ring = [Float](repeating: 0, count: LevelMeter.capacity)
    private var carry: [Float] = []
    private var written = 0
    private let lock = NSLock()

    /// Total number of slices produced since the last reset.
    var sliceCount: Int {
        lock.lock(); defer { lock.unlock() }
        return written
    }

    func reset() {
        lock.lock()
        written = 0
        carry.removeAll(keepingCapacity: true)
        for index in ring.indices { ring[index] = 0 }
        lock.unlock()
    }

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        carry.append(contentsOf: UnsafeBufferPointer(start: samples, count: count))
        var offset = 0
        carry.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            while buffer.count - offset >= LevelMeter.sliceSamples {
                var rms: Float = 0
                vDSP_rmsqv(base + offset, 1, &rms, vDSP_Length(LevelMeter.sliceSamples))
                ring[written % LevelMeter.capacity] = LevelMeter.normalize(rms)
                written += 1
                offset += LevelMeter.sliceSamples
            }
        }
        if offset > 0 { carry.removeFirst(offset) }
        lock.unlock()
    }

    /// Levels for slices `[end - count, end)`, oldest first. Slices outside the history are zero.
    func levels(endingAt end: Int, count: Int) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        var result = [Float](repeating: 0, count: count)
        for index in 0..<count {
            let slice = end - count + index
            if slice >= 0, slice < written, written - slice <= LevelMeter.capacity {
                result[index] = ring[slice % LevelMeter.capacity]
            }
        }
        return result
    }

    /// Maps RMS amplitude to 0...1 on a decibel scale (about -52 dBFS is silence, -12 dBFS is loud speech).
    static func normalize(_ rms: Float) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels + 52) / 40))
    }
}
