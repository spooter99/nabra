import AppKit

/// Soft cues for start, stop and errors, synthesised at launch (no audio files to ship).
///
/// Each cue is a single pure tone that glides a little in pitch, with a smooth fade in and out.
/// No sharp attack and no overtones, so they read as a gentle "blip" rather than a beep.
final class SoundEffects {
    enum Cue {
        case start
        case stop
        case error
    }

    private var sounds: [Cue: NSSound] = [:]

    init() {
        sounds[.start] = SoundEffects.makeSound(from: 392, to: 494, duration: 0.11)
        sounds[.stop] = SoundEffects.makeSound(from: 440, to: 349, duration: 0.12)
        sounds[.error] = SoundEffects.makeSound(from: 294, to: 247, duration: 0.22)
    }

    /// Plays a cue. `volume` runs from 0 (silent) to 1.
    func play(_ cue: Cue, volume: Double) {
        guard volume > 0.01, let sound = sounds[cue] else { return }
        if sound.isPlaying { sound.stop() }
        // The slider is perceptual: square it so the low end stays very quiet.
        sound.volume = Float(min(1, volume * volume))
        sound.play()
    }

    private static func makeSound(from startFrequency: Double, to endFrequency: Double, duration: Double) -> NSSound? {
        let sampleRate = 44_100.0
        let count = Int(duration * sampleRate)
        let attack = duration * 0.35
        var samples: [Int16] = []
        samples.reserveCapacity(count)
        var phase = 0.0
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let progress = time / duration
            let frequency = startFrequency + (endFrequency - startFrequency) * progress
            phase += 2 * .pi * frequency / sampleRate
            // Raised-cosine fade in, then a longer raised-cosine fade out: no clicks at either end.
            let envelope = time < attack
                ? 0.5 * (1 - cos(.pi * time / attack))
                : 0.5 * (1 + cos(.pi * (time - attack) / (duration - attack)))
            samples.append(Int16(sin(phase) * envelope * 0.6 * Double(Int16.max)))
        }
        var data = Data()
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); append(UInt32(16).littleEndian)
        append(UInt16(1).littleEndian); append(UInt16(1).littleEndian)
        append(UInt32(sampleRate).littleEndian); append(UInt32(sampleRate * 2).littleEndian)
        append(UInt16(2).littleEndian); append(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); append(byteCount.littleEndian)
        samples.forEach { append($0.littleEndian) }
        return NSSound(data: data)
    }
}
