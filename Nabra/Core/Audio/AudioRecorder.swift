import AVFoundation
import CoreAudio
import Foundation

/// Captures the microphone as 16 kHz mono float samples.
///
/// A fresh AVAudioEngine is created for every recording: that avoids stale hardware formats after
/// devices change, which is the usual cause of AVAudioEngine crashes.
final class AudioRecorder {
    enum RecorderError: LocalizedError {
        case microphoneAccessDenied
        case noInputDevice
        case engine(String)

        var errorDescription: String? {
            switch self {
            case .microphoneAccessDenied: return "Microphone access is off"
            case .noInputDevice: return "No microphone found"
            case .engine(let reason): return "Microphone error: \(reason)"
            }
        }
    }

    let meter = LevelMeter()

    private let queue = DispatchQueue(label: "app.nabra.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var samples: [Float] = []

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var monoScratch: AVAudioPCMBuffer?
    private var configurationObserver: NSObjectProtocol?
    private var deviceUID: String?
    private var startedAt: UInt64 = 0
    private var loggedFirstBuffer = false

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(SpeechEngine.sampleRate),
                                             channels: 1,
                                             interleaved: false)!

    /// Number of 16 kHz samples captured so far. Thread-safe.
    var sampleCount: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    /// Copies captured samples in `range` (clamped). Thread-safe.
    func copySamples(in range: Range<Int>) -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let lower = max(0, min(range.lowerBound, samples.count))
        let upper = max(lower, min(range.upperBound, samples.count))
        return Array(samples[lower..<upper])
    }

    /// Starts capturing. `completion` runs on the main queue once audio is flowing or has failed.
    func start(deviceUID: String?, completion: @escaping (Result<Void, Error>) -> Void) {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(SpeechEngine.sampleRate * 60)
        lock.unlock()
        meter.reset()

        queue.async { [self] in
            let result: Result<Void, Error>
            do {
                self.deviceUID = deviceUID
                try startEngine()
                result = .success(())
            } catch {
                teardownEngine()
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Stops capturing and returns everything recorded.
    func finish() -> [Float] {
        queue.sync { teardownEngine() }
        lock.lock(); defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }

    func cancel() {
        queue.async { [self] in
            teardownEngine()
            lock.lock()
            samples = []
            lock.unlock()
        }
    }

    // MARK: - Engine (audio queue)

    private func startEngine() throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphoneAccessDenied
        }
        teardownEngine()
        startedAt = DispatchTime.now().uptimeNanoseconds
        loggedFirstBuffer = false

        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let deviceUID, let device = AudioDevices.device(forUID: deviceUID), let unit = input.audioUnit {
            var deviceID = device.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("Could not select input device \(device.name): \(status)") }
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }

        var objcError: NSError?
        let installed = NabraTryObjC({
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
                self?.consume(buffer)
            }
        }, &objcError)
        guard installed else {
            throw RecorderError.engine(objcError?.localizedDescription ?? "could not attach to the microphone")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engine(error.localizedDescription)
        }
        self.engine = engine

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.restartAfterConfigurationChange() }
        }
        Log.info("Audio started: \(Int(hardwareFormat.sampleRate)) Hz, \(hardwareFormat.channelCount) ch")
    }

    private func teardownEngine() {
        if let observer = configurationObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationObserver = nil
        }
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        converter = nil
        converterSourceFormat = nil
        monoScratch = nil
    }

    /// The input device changed mid-recording (headset plugged in, AirPods connected): keep going on the new one.
    private func restartAfterConfigurationChange() {
        guard engine != nil else { return }
        Log.info("Audio configuration changed, restarting capture")
        do {
            try startEngine()
        } catch {
            Log.error("Could not restart capture: \(error.localizedDescription)")
            teardownEngine()
        }
    }

    // MARK: - Conversion (audio tap thread)

    private func consume(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000
            Log.info(String(format: "First audio buffer after %.0f ms (%d frames)", ms, Int(buffer.frameLength)))
        }

        let source = downmixToMono(buffer) ?? buffer
        let sourceFormat = source.format
        if converter == nil || converterSourceFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            if sourceFormat.channelCount > 1 { converter?.channelMap = [0] }
            converterSourceFormat = sourceFormat
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        guard status != .error, let channel = output.floatChannelData, output.frameLength > 0 else { return }
        let count = Int(output.frameLength)
        lock.lock()
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: count))
        lock.unlock()
        meter.push(channel[0], count: count)
    }

    /// Averages all channels of a deinterleaved float buffer into one. Returns nil when not applicable.
    private func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let format = buffer.format
        let channels = Int(format.channelCount)
        guard channels > 1, format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let sourceChannels = buffer.floatChannelData,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                             channels: 1, interleaved: false)
        else { return nil }
        if monoScratch == nil || monoScratch!.format != monoFormat || monoScratch!.frameCapacity < buffer.frameLength {
            monoScratch = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: max(buffer.frameLength, 8192))
        }
        guard let mono = monoScratch, let destination = mono.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += sourceChannels[channel][frame] }
            destination[frame] = sum * scale
        }
        mono.frameLength = buffer.frameLength
        return mono
    }
}
