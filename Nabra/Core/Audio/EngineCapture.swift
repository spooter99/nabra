import AVFoundation
import CoreAudio
import Foundation

/// Microphone capture through AVAudioEngine.
///
/// Slower to start than `HALCapture` (the engine is built fresh each time, which avoids stale
/// hardware formats), but it copes with every kind of device. Used for Bluetooth microphones,
/// whose format changes when they switch to their call profile, and as the fallback whenever the
/// fast path cannot start.
final class EngineCapture {
    /// 16 kHz mono samples and the uptime at which the first of them was captured (0 if unknown).
    /// Called on the engine's tap thread.
    var onSamples: ((UnsafeBufferPointer<Float>, _ capturedAt: UInt64) -> Void)?
    /// The device changed under the engine (headset connected, format switched). Called on an arbitrary thread.
    var onConfigurationChange: (() -> Void)?

    private(set) var sampleRate: Double = 0
    private(set) var channels = 0

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var monoScratch: AVAudioPCMBuffer?
    private var configurationObserver: NSObjectProtocol?

    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: Double(SpeechEngine.sampleRate),
                                             channels: 1,
                                             interleaved: false)!

    deinit {
        stop()
    }

    /// `deviceID` nil follows the system default input.
    func start(deviceID: AudioDeviceID?) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let deviceID, let unit = input.audioUnit {
            var device = deviceID
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &device, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.error("Could not select input device \(deviceID): \(status)") }
        }

        let hardwareFormat = input.outputFormat(forBus: 0)
        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            throw CaptureError.noInputDevice
        }
        sampleRate = hardwareFormat.sampleRate
        channels = Int(hardwareFormat.channelCount)

        var objcError: NSError?
        let installed = NabraTryObjC({
            input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, when in
                self?.consume(buffer, when: when)
            }
        }, &objcError)
        guard installed else {
            throw CaptureError.engine(objcError?.localizedDescription ?? "could not attach to the microphone")
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engine(error.localizedDescription)
        }
        self.engine = engine

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    func stop() {
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

    var isRunning: Bool { engine != nil }

    // MARK: - Conversion (tap thread)

    private func consume(_ buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard buffer.frameLength > 0 else { return }
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
        let capturedAt = when.isHostTimeValid ? AudioConvertHostTimeToNanos(when.hostTime) : 0
        onSamples?(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)), capturedAt)
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
