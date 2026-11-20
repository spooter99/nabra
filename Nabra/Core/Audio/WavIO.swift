import AVFoundation
import Foundation

/// Reading and writing audio files as 16 kHz mono float samples.
enum AudioFileIO {
    enum IOError: LocalizedError {
        case unreadable(String)
        var errorDescription: String? {
            switch self {
            case .unreadable(let path): return "Could not read audio from \(path)."
            }
        }
    }

    /// Loads any file AVFoundation can decode and converts it to 16 kHz mono.
    static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Double(SpeechEngine.sampleRate),
                                               channels: 1,
                                               interleaved: false),
              let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                                  frameCapacity: AVAudioFrameCount(max(1, file.length)))
        else { throw IOError.unreadable(url.path) }
        try file.read(into: sourceBuffer)

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            throw IOError.unreadable(url.path)
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return sourceBuffer
        }
        guard status != .error, conversionError == nil, let channel = output.floatChannelData else {
            throw IOError.unreadable(url.path)
        }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// Writes samples as compressed AAC (.m4a): roughly 4 kB per second of speech.
    static func writeCompressed(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(SpeechEngine.sampleRate),
                                         channels: 1,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let channel = buffer.floatChannelData
        else { throw IOError.unreadable(url.path) }
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel[0].update(from: base, count: samples.count) }
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Double(SpeechEngine.sampleRate),
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
