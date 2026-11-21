import AVFoundation
import CoreAudio
import Foundation

/// Measures how long the microphone takes to deliver its first sample on each capture path.
///
///   Nabra --capture-bench <report file> [--runs 4] [--gap 5] [--paths direct,fresh,engine]
///
/// Launch it through `open` so it runs under Nabra's own microphone permission:
///   open -n -g Nabra.app --args --capture-bench /path/report.txt
///
/// For every run it reports, in milliseconds after the start call: when the call returned, when
/// the first audio reached the app, and when that first sample was captured (the audio before
/// that moment is what a dictation loses). It also reports how much of the last moment before
/// the stop call never arrived. Nothing recorded is kept.
enum CaptureBench {
    private final class Probe {
        private let lock = NSLock()
        private var firstArrival: UInt64 = 0
        private var firstCaptured: UInt64 = 0
        private var samples: [Float] = []
        private var total = 0

        func add(_ buffer: UnsafeBufferPointer<Float>, capturedAt: UInt64) {
            lock.lock()
            if firstArrival == 0 {
                firstArrival = Uptime.now
                firstCaptured = capturedAt
            }
            if samples.count < SpeechEngine.sampleRate { samples.append(contentsOf: buffer) }
            total += buffer.count
            lock.unlock()
        }

        var result: (arrival: UInt64, captured: UInt64, samples: [Float], total: Int) {
            lock.lock(); defer { lock.unlock() }
            return (firstArrival, firstCaptured, samples, total)
        }
    }

    static func run(reportPath: String, runs: Int, gap: Double, paths: [String]) -> Int32 {
        var lines: [String] = []
        func emit(_ line: String) {
            lines.append(line)
            try? (lines.joined(separator: "\n") + "\n").write(toFile: reportPath, atomically: true, encoding: .utf8)
        }

        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .authorized else {
            emit("microphone permission: \(status.rawValue) (not authorized)")
            return 1
        }
        guard let device = AudioDevices.defaultInputDevice() else {
            emit("no input device")
            return 1
        }
        emit("device: \(device.name) wireless=\(device.isWireless) rate=\(Int(AudioDevices.nominalSampleRate(device.id)))")
        emit("running before anything: \(HALCapture.deviceIsRunningSomewhere(device.id))")

        let queue = DispatchQueue(label: "app.nabra.bench", qos: .userInteractive)
        var prepared: HALCapture?
        if paths.contains("direct") {
            let started = Uptime.now
            do {
                prepared = try queue.sync { try HALCapture.make(deviceID: device.id, queue: queue) }
                emit(String(format: "prepared direct unit in %.1f ms: %@", Uptime.milliseconds(from: started, to: Uptime.now),
                            String(describing: prepared!.description)))
            } catch {
                emit("could not prepare: \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 0.3)
            emit("running after prepare (must be false, or the microphone light would stay on): "
                + "\(HALCapture.deviceIsRunningSomewhere(device.id))")
        }

        emit("path\tgap_s\tbusy_before\tstart_returned_ms\tfirst_audio_ms\tfirst_sample_ms\ttail_lost_ms\thearing_after_ms\tlevel_dB_per_10ms")
        for run in 0..<runs {
            for path in paths {
                Thread.sleep(forTimeInterval: gap)
                let busy = HALCapture.deviceIsRunningSomewhere(device.id)
                let probe = Probe()
                let started = Uptime.now
                var returned = started
                var failure: String?
                var direct: HALCapture?
                var engine: EngineCapture?
                switch path {
                case "direct", "fresh":
                    queue.sync {
                        do {
                            let capture = try path == "direct" && prepared != nil
                                ? prepared! : HALCapture.make(deviceID: device.id, queue: queue)
                            capture.onSamples = { probe.add($0, capturedAt: $1) }
                            try capture.start()
                            direct = capture
                        } catch {
                            failure = error.localizedDescription
                        }
                        returned = Uptime.now
                    }
                default:
                    let capture = EngineCapture()
                    capture.onSamples = { probe.add($0, capturedAt: $1) }
                    do {
                        try capture.start(deviceID: nil)
                        engine = capture
                    } catch {
                        failure = error.localizedDescription
                    }
                    returned = Uptime.now
                }
                if let failure {
                    emit("\(path)\t\(gap)\t\(busy)\tFAILED: \(failure)")
                    continue
                }
                // Wait for the first audio (up to 5 s), then a little more to see the signal come up.
                let deadline = Date().addingTimeInterval(5)
                while probe.result.arrival == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
                Thread.sleep(forTimeInterval: 0.35)
                let whileRunning = HALCapture.deviceIsRunningSomewhere(device.id)
                // Stop at an arbitrary moment, as a key release would.
                Thread.sleep(forTimeInterval: Double.random(in: 0...0.1))
                let stopCalled = Uptime.now
                queue.sync {
                    direct?.stop()
                    direct?.onSamples = nil
                    if path == "fresh" { direct?.dispose() }
                }
                engine?.stop()

                let result = probe.result
                // When the start-up gate would say the microphone is really hearing.
                var gate = StartupGate()
                _ = result.samples.withUnsafeBufferPointer { gate.feed($0) }
                let hearing = gate.isOpen ? String(format: "%.0f", Double(gate.deadSamples) / Double(SpeechEngine.sampleRate) * 1000) : "never"
                let slice = SpeechEngine.sampleRate / 100
                var levels: [String] = []
                var offset = 0
                while offset + slice <= result.samples.count, levels.count < 26 {
                    var sum: Float = 0
                    for index in offset..<(offset + slice) { sum += result.samples[index] * result.samples[index] }
                    let rms = (sum / Float(slice)).squareRoot()
                    levels.append(rms > 0 ? String(format: "%.0f", 20 * log10(rms)) : "-inf")
                    offset += slice
                }
                let arrival = result.arrival == 0 ? "none" : String(format: "%.1f", Uptime.milliseconds(from: started, to: result.arrival))
                let captured = result.captured == 0 ? "?" : String(format: "%.1f", Uptime.milliseconds(from: started, to: result.captured))
                // Audio delivered covers [first sample, first sample + count / rate]; the rest up to the stop call is lost.
                let tail = result.captured == 0 ? "?" : String(format: "%.1f", Uptime.milliseconds(from: result.captured, to: stopCalled)
                    - Double(result.total) / Double(SpeechEngine.sampleRate) * 1000)
                emit(String(format: "%@\t%.0f\t%@\t%.1f\t%@\t%@\t%@\t%@\t%@%@", path, gap, String(busy),
                            Uptime.milliseconds(from: started, to: returned), arrival, captured, tail, hearing,
                            levels.joined(separator: " "), whileRunning ? "" : "  (device not reported running!)"))
                _ = run
            }
        }
        queue.sync { prepared?.dispose() }
        emit("done")
        return 0
    }
}
