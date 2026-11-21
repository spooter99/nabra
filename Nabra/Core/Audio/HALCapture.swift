import Accelerate
import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation
import os

enum CaptureError: LocalizedError {
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

/// Converts mono float audio at the microphone's rate to 16 kHz, keeping filter state between calls
/// so consecutive blocks join without a seam.
final class Resampler {
    /// Fill `input` (channel 0), then call `convert(frames:)`.
    let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer?
    private let converter: AVAudioConverter?

    /// `capacity` is the largest number of input frames passed to one `convert` call.
    init?(sampleRate: Double, capacity: Int) {
        guard sampleRate > 0,
              let source = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechEngine.sampleRate),
                                         channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(max(capacity, 1)))
        else { return nil }
        self.input = input
        if sampleRate == target.sampleRate {
            converter = nil
            output = nil
        } else {
            let frames = AVAudioFrameCount(Double(capacity) * target.sampleRate / sampleRate) + 1024
            guard let converter = AVAudioConverter(from: source, to: target),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: frames)
            else { return nil }
            self.converter = converter
            self.output = output
        }
    }

    /// Converts the first `frames` frames of `input`. With `flush`, also emits what the filter still holds
    /// and leaves the converter ready for a new stream.
    func convert(frames: Int, flush: Bool, deliver: (UnsafeBufferPointer<Float>) -> Void) {
        guard let converter, let output else {
            if frames > 0, let channel = input.floatChannelData {
                deliver(UnsafeBufferPointer(start: channel[0], count: frames))
            }
            return
        }
        input.frameLength = AVAudioFrameCount(frames)
        var supplied = frames == 0
        var rounds = 0
        while rounds < 4 {
            rounds += 1
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { [input] _, inputStatus in
                if supplied {
                    inputStatus.pointee = flush ? .endOfStream : .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            if status == .error { break }
            if output.frameLength > 0, let channel = output.floatChannelData {
                deliver(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            // `.haveData` means the output buffer filled up before the input ran out: go round again.
            if status != .haveData { break }
        }
        if flush { converter.reset() }
    }

    func reset() {
        converter?.reset()
    }
}

/// Microphone capture through an input unit (AUHAL) that is completely set up ahead of time.
///
/// Everything slow — finding the device, negotiating formats, allocating buffers — happens in
/// `make`. `start()` then only has to start the hardware, which is what makes the first word of a
/// dictation land in the recording. The audio thread does nothing but copy; conversion to 16 kHz
/// happens on `queue`.
final class HALCapture {
    struct Description: Equatable {
        var deviceID: AudioDeviceID
        var sampleRate: Double
        var channels: Int
        var ioFrames: Int
    }

    let description: Description
    /// 16 kHz mono samples and the uptime at which the first of them was captured (0 if unknown).
    /// Called on `queue`.
    var onSamples: ((UnsafeBufferPointer<Float>, _ capturedAt: UInt64) -> Void)?

    private let unit: AudioUnit
    private let queue: DispatchQueue
    private let signal: DispatchSourceUserDataAdd
    private let resampler: Resampler

    // Audio-thread scratch.
    private let maxFrames: Int
    private let channelStorage: UnsafeMutablePointer<Float>
    private let monoScratch: UnsafeMutablePointer<Float>
    private let bufferList: UnsafeMutableAudioBufferListPointer

    // Handed from the audio thread to `queue` under `lock`.
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private let pending: UnsafeMutablePointer<Float>
    private let pendingCapacity: Int
    private var pendingCount = 0
    private var pendingFirstHostTime: UInt64 = 0
    private var droppedFrames = 0

    private var running = false
    private var disposed = false

    /// Builds and initialises the unit for `deviceID`. Does not start the microphone.
    static func make(deviceID: AudioDeviceID, queue: DispatchQueue) throws -> HALCapture {
        var componentDescription = AudioComponentDescription(componentType: kAudioUnitType_Output,
                                                             componentSubType: kAudioUnitSubType_HALOutput,
                                                             componentManufacturer: kAudioUnitManufacturer_Apple,
                                                             componentFlags: 0,
                                                             componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &componentDescription) else {
            throw CaptureError.engine("no input unit available")
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "create the input unit")
        guard let unit = instance else { throw CaptureError.engine("no input unit available") }

        // Once a HALCapture owns the unit, releasing it is that object's job.
        var owner: HALCapture?
        do {
            var on: UInt32 = 1
            var off: UInt32 = 0
            let flagSize = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, flagSize),
                      "enable input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, flagSize),
                      "disable output")
            var device = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                                           UInt32(MemoryLayout<AudioDeviceID>.size)), "select the microphone")

            var hardware = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &formatSize),
                      "read the microphone format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0 else { throw CaptureError.noInputDevice }

            // Ask for plain float samples, one buffer per channel, at the device's own rate.
            var client = AudioStreamBasicDescription(
                mSampleRate: hardware.mSampleRate,
                mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: hardware.mChannelsPerFrame, mBitsPerChannel: 32, mReserved: 0)
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, formatSize),
                      "set the capture format")

            let ioFrames = HALCapture.prepareIOBuffer(deviceID: deviceID)
            let description = Description(deviceID: deviceID, sampleRate: hardware.mSampleRate,
                                          channels: Int(hardware.mChannelsPerFrame), ioFrames: ioFrames)
            guard let capture = HALCapture(unit: unit, description: description, queue: queue) else {
                throw CaptureError.engine("could not set up conversion")
            }
            owner = capture
            var callback = AURenderCallbackStruct(inputProc: halInputCallback,
                                                  inputProcRefCon: Unmanaged.passUnretained(capture).toOpaque())
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                                           UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "attach to the microphone")
            try check(AudioUnitInitialize(unit), "initialise the microphone")
            return capture
        } catch {
            if let owner {
                owner.dispose()
            } else {
                AudioComponentInstanceDispose(unit)
            }
            throw error
        }
    }

    private init?(unit: AudioUnit, description: Description, queue: DispatchQueue) {
        self.unit = unit
        self.description = description
        self.queue = queue
        maxFrames = max(4096, description.ioFrames * 2)
        // Two seconds of headroom between the audio thread and the conversion queue.
        pendingCapacity = max(Int(description.sampleRate * 2), maxFrames * 2)
        guard let resampler = Resampler(sampleRate: description.sampleRate, capacity: pendingCapacity) else { return nil }
        self.resampler = resampler

        channelStorage = .allocate(capacity: maxFrames * description.channels)
        channelStorage.initialize(repeating: 0, count: maxFrames * description.channels)
        monoScratch = .allocate(capacity: maxFrames)
        monoScratch.initialize(repeating: 0, count: maxFrames)
        bufferList = AudioBufferList.allocate(maximumBuffers: description.channels)
        pending = .allocate(capacity: pendingCapacity)
        pending.initialize(repeating: 0, count: pendingCapacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        signal = DispatchSource.makeUserDataAddSource(queue: queue)
        signal.setEventHandler { [weak self] in self?.drain(flush: false) }
        signal.resume()
    }

    deinit {
        dispose()
        signal.cancel()
        channelStorage.deallocate()
        monoScratch.deallocate()
        free(bufferList.unsafeMutablePointer)
        pending.deallocate()
        lock.deallocate()
    }

    /// Stops and releases the unit. The object cannot be used afterwards.
    func dispose() {
        guard !disposed else { return }
        disposed = true
        if running { AudioOutputUnitStop(unit) }
        running = false
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    // MARK: - Control (call on `queue`)

    func start() throws {
        guard !disposed else { throw CaptureError.engine("the input unit was released") }
        os_unfair_lock_lock(lock)
        pendingCount = 0
        pendingFirstHostTime = 0
        droppedFrames = 0
        os_unfair_lock_unlock(lock)
        resampler.reset()
        let status = AudioOutputUnitStart(unit)
        guard status == noErr else { throw CaptureError.engine("could not start the microphone (\(status))") }
        running = true
    }

    /// Stops the microphone and delivers everything captured up to this moment.
    func stop() {
        guard running, !disposed else { return }
        AudioOutputUnitStop(unit)
        running = false
        drain(flush: true)
        if droppedFrames > 0 { Log.error("Capture dropped \(droppedFrames) frames (conversion fell behind)") }
    }

    var isRunning: Bool { running }

    /// Delivers whatever the audio thread has handed over so far, without stopping.
    func flushPending() {
        guard running, !disposed else { return }
        drain(flush: false)
    }

    // MARK: - Audio thread

    fileprivate func render(_ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                            _ timeStamp: UnsafePointer<AudioTimeStamp>,
                            _ frameCount: UInt32) -> OSStatus {
        let frames = Int(frameCount)
        guard frames > 0, frames <= maxFrames else { return kAudioUnitErr_TooManyFramesToProcess }
        let channels = description.channels
        bufferList.count = channels
        for channel in 0..<channels {
            bufferList[channel] = AudioBuffer(mNumberChannels: 1,
                                              mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                                              mData: UnsafeMutableRawPointer(channelStorage + channel * maxFrames))
        }
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frameCount, bufferList.unsafeMutablePointer)
        guard status == noErr else { return status }

        var mono = channelStorage
        if channels > 1 {
            memcpy(monoScratch, channelStorage, frames * MemoryLayout<Float>.size)
            for channel in 1..<channels {
                vDSP_vadd(monoScratch, 1, channelStorage + channel * maxFrames, 1, monoScratch, 1, vDSP_Length(frames))
            }
            var scale = 1 / Float(channels)
            vDSP_vsmul(monoScratch, 1, &scale, monoScratch, 1, vDSP_Length(frames))
            mono = monoScratch
        }

        os_unfair_lock_lock(lock)
        if pendingCount + frames <= pendingCapacity {
            if pendingCount == 0 {
                let stamp = timeStamp.pointee
                pendingFirstHostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : 0
            }
            memcpy(pending + pendingCount, mono, frames * MemoryLayout<Float>.size)
            pendingCount += frames
        } else {
            droppedFrames += frames
        }
        os_unfair_lock_unlock(lock)
        signal.add(data: 1)
        return noErr
    }

    // MARK: - Conversion (on `queue`)

    private func drain(flush: Bool) {
        guard let destination = resampler.input.floatChannelData?[0] else { return }
        os_unfair_lock_lock(lock)
        let frames = pendingCount
        let hostTime = pendingFirstHostTime
        if frames > 0 { memcpy(destination, pending, frames * MemoryLayout<Float>.size) }
        pendingCount = 0
        pendingFirstHostTime = 0
        os_unfair_lock_unlock(lock)
        guard frames > 0 || flush else { return }
        let capturedAt = hostTime != 0 ? AudioConvertHostTimeToNanos(hostTime) : 0
        resampler.convert(frames: frames, flush: flush) { [weak self] samples in
            self?.onSamples?(samples, capturedAt)
        }
    }

    // MARK: - Device helpers

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw CaptureError.engine("could not \(action) (\(status))") }
    }

    /// Makes sure the device hands over audio in small blocks, and returns the block size in frames.
    private static func prepareIOBuffer(deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var frames: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &frames) == noErr else { return 512 }
        if frames > 1024 {
            var wanted: UInt32 = 512
            if AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &wanted) == noErr {
                var actual: UInt32 = 0
                if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &actual) == noErr, actual > 0 { frames = actual }
            }
        }
        return Int(frames)
    }

    /// Whether any app (including this one) currently has the device running.
    static func deviceIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

private let halInputCallback: AURenderCallback = { refCon, flags, timeStamp, _, frameCount, _ in
    Unmanaged<HALCapture>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, frameCount)
}
