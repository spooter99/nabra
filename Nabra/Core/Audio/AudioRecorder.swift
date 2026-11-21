import AVFoundation
import CoreAudio
import Foundation

/// Captures the microphone as 16 kHz mono float samples, one `Take` per dictation.
///
/// Everything here serves one goal: the first word of a dictation must be in the recording.
///
/// - The input unit is set up before it is needed (`prepare`), so `begin` only starts the hardware.
/// - A microphone that is already open is handed to the next take without being restarted, so a
///   press that follows a release closely loses nothing.
/// - `StartupGate` tells when a freshly started microphone really begins to hear (a built-in one is
///   silent for its first 0.2 s), so the indicator and the start cue never claim it earlier.
/// - Optionally the microphone is kept open between dictations (`setStandby`). Then nothing at all
///   is lost, and each take even includes a moment from before its key went down.
///
/// Two capture paths exist: `HALCapture`, prepared in advance, for built-in and wired microphones,
/// and `EngineCapture` (AVAudioEngine) for Bluetooth ones and as the fallback whenever the fast
/// path fails to start or delivers nothing.
final class AudioRecorder {
    /// Whether the microphone stays open when nobody is dictating.
    enum Standby: Equatable {
        /// It opens when a dictation starts and closes when it ends.
        case never
        /// It stays open this long after a dictation, so the next one in a row starts with it already on.
        case after(TimeInterval)
        /// It is open whenever the app runs.
        case always
    }

    let meter = LevelMeter()

    /// The microphone is really being heard for this take. Main queue, once per take.
    var onSoundStarted: ((Take) -> Void)?
    /// Capture for a take could not start, or stopped delivering. Main queue.
    var onFailure: ((Take, Error) -> Void)?

    /// Test hook: when set, takes are fed from these samples in real time instead of the microphone.
    var simulatedInput: [Float]?

    /// With the microphone kept open, this much audio from before `begin` is put at the start of a take.
    static let preRollSamples = SpeechEngine.sampleRate * 15 / 100

    private let queue = DispatchQueue(label: "app.nabra.audio", qos: .userInteractive)

    // Where the audio of the running stream goes. Under `routeLock`; read from the capture threads.
    private let routeLock = NSLock()
    private var routedTake: Take?
    private var currentTake: Take?
    private var nextTakeID = 1
    /// The hardware has been started: audio is arriving or about to.
    private var streamLive = false
    private var streamBackend = ""
    private var gate = StartupGate()
    private var ring = SampleRing(capacity: SpeechEngine.sampleRate)
    /// When the first sample of the running stream was picked up.
    private var streamFirstSample: UInt64 = 0
    private var delivered = 0
    private var fastPathReady = false
    private var standby = Standby.never
    /// Uptime until which an open microphone is not closed (a dictation is still being worked on).
    private var heldOpenUntil: UInt64 = 0

    // Everything below is confined to `queue`.
    private struct Stream {
        var hal: HALCapture?
        var engine: EngineCapture?
        var feed: DispatchSourceTimer?
        var lastDelivered = 0
        var lastProgress = Uptime.now
        var restarts = 0
    }

    private var stream: Stream?
    private var wantedUID: String?
    private var prepared: HALCapture?
    private var preparedDevice: AudioDevices.Device?
    /// The microphone choice (`wantedUID`) the prepared unit was built for.
    private var preparedForUID: String?
    private var prepareWork: DispatchWorkItem?
    private var watchdog: DispatchSourceTimer?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var listenedDevice: AudioDeviceID = 0
    private var systemListenersInstalled = false
    /// When the last real dictation ended (for `Standby.after`).
    private var lastDictationEnded: UInt64 = 0
    private var lingerWork: DispatchWorkItem?
    /// Set when the fast path started but produced no audio: it is left alone for a while.
    private var directBlockedUntil: UInt64 = 0
    private var loggedUnpreparable = false
    private var streamBackendForLog: String {
        routeLock.lock(); defer { routeLock.unlock() }
        return streamBackend.isEmpty ? "unknown" : streamBackend
    }

    private static let forcedBackend = ProcessInfo.processInfo.environment["NABRA_CAPTURE"]

    // MARK: - SampleSource view of the latest take

    /// Number of 16 kHz samples captured so far in the latest take. Thread-safe.
    var sampleCount: Int { latestTake?.sampleCount ?? 0 }

    /// Copies captured samples of the latest take in `range` (clamped). Thread-safe.
    func copySamples(in range: Range<Int>) -> [Float] {
        latestTake?.copySamples(in: range) ?? []
    }

    private var latestTake: Take? {
        routeLock.lock(); defer { routeLock.unlock() }
        return currentTake
    }

    /// True when opening the microphone is quick and has no side effects worth avoiding, so it is
    /// fine to open it the moment the dictation key goes down, before knowing whether this press is
    /// a dictation. False for Bluetooth microphones (opening one switches the headphones to their
    /// call profile) and before `prepare` has finished.
    var canStartEarly: Bool {
        routeLock.lock(); defer { routeLock.unlock() }
        return fastPathReady || streamLive
    }

    /// True when audio reaches a take within a few milliseconds of being spoken (the fast path).
    /// The AVAudioEngine path hands audio over in tenth-of-a-second blocks instead.
    var deliversPromptly: Bool {
        routeLock.lock(); defer { routeLock.unlock() }
        return streamBackend != "engine"
    }

    /// Whether the microphone is switched on right now.
    var isMicrophoneOpen: Bool {
        routeLock.lock(); defer { routeLock.unlock() }
        return streamLive
    }

    // MARK: - Public control

    /// Sets the microphone up ahead of time. Safe to call often; does not turn the microphone on.
    func prepare(deviceUID: String?) {
        queue.async { [self] in
            wantedUID = deviceUID
            prepareNow()
        }
    }

    /// Chooses whether the microphone stays open between dictations (built-in and wired microphones
    /// only). macOS shows its microphone indicator for as long as it is open.
    func setStandby(_ policy: Standby) {
        routeLock.lock()
        let changed = standby != policy
        standby = policy
        routeLock.unlock()
        guard changed else { return }
        queue.async { [self] in
            switch policy {
            case .never: Log.info("Microphone opens only while dictating")
            case .after(let seconds): Log.info("Microphone stays open for \(Int(seconds)) s after each dictation")
            case .always: Log.info("Microphone is kept open between dictations")
            }
            settle()
        }
    }

    /// While a dictation is still being turned into text, an open microphone is left open: a press
    /// that comes during that moment then starts with the microphone already hearing. It is closed as
    /// soon as the work is done (`busy` false), and after eight seconds whatever happens.
    func keepOpenWhileBusy(_ busy: Bool) {
        routeLock.lock()
        let wasHeld = heldOpenUntil != 0
        heldOpenUntil = busy ? Uptime.now + 8_000_000_000 : 0
        routeLock.unlock()
        guard wasHeld != busy else { return }
        queue.async { [self] in settle() }
    }

    /// Starts capturing into a new take and returns it at once.
    func begin(deviceUID: String?) -> Take {
        routeLock.lock()
        let take = Take(id: nextTakeID)
        nextTakeID += 1
        let previous = routedTake
        var soundAlready = false
        if streamLive {
            // The microphone is open already (the previous dictation is still winding down, or it is
            // kept open on purpose): take it over as it is, without a gap.
            // Audio from just before the key is only used when the user chose to keep the microphone on.
            if previous == nil, gate.isOpen, standby != .never { take.prefill(ring.latest(AudioRecorder.preRollSamples)) }
            // What the buffer held belongs to before this take; it must never reach a later one.
            ring.clear()
            take.noteCaptureStarted(backend: streamBackend + ", already open")
            if gate.isOpen { soundAlready = take.markSoundStarted() }
        }
        routedTake = take
        currentTake = take
        routeLock.unlock()
        // The take before this one stops growing the instant the new one takes over.
        previous?.seal()
        meter.reset()
        if soundAlready {
            DispatchQueue.main.async { [weak self] in self?.onSoundStarted?(take) }
        }
        queue.async { [self] in
            wantedUID = deviceUID
            prepareWork?.cancel()
            if take.isSealed {
                // Discarded before the microphone was even asked to start.
                detach(take)
                settle()
            } else if stream == nil {
                startStream(for: take)
            }
        }
        return take
    }

    /// Stops capturing into `take` and hands back everything recorded. `completion` runs on the main queue.
    func finish(_ take: Take, completion: @escaping ([Float]) -> Void) {
        queue.async { [self] in
            // Collect what the audio thread has handed over up to this moment.
            stream?.hal?.flushPending()
            detach(take)
            take.seal()
            let samples = take.allSamples()
            DispatchQueue.main.async { completion(samples) }
            lastDictationEnded = Uptime.now
            let seconds = Double(samples.count) / Double(SpeechEngine.sampleRate)
            if seconds < 0.05 || (seconds > 0.3 && samples.allSatisfy { $0 == 0 }) {
                // Nothing, or only digital silence: whatever was set up for the microphone is not to be
                // trusted for the next press (another app may have changed the device under us).
                Log.error(String(format: "Take %d got %@ (%.1f s on the %@ path); the microphone is set up afresh for the next one",
                                 take.id, seconds < 0.05 ? "no audio" : "only silence", seconds,
                                 streamBackendForLog))
                stopStream()
                dropPrepared()
                directBlockedUntil = 0
            }
            settle()
            schedulePrepare(after: 0.3)
        }
    }

    /// Stops capturing into `take` and throws it away.
    func discard(_ take: Take) {
        // Sealed at once, so a start that has not run yet is skipped entirely.
        take.seal()
        queue.async { [self] in
            detach(take)
            settle()
        }
    }

    /// The Mac has just woken up. An input unit set up before sleep may no longer work, so build a
    /// new one (and reopen the microphone if it is meant to stay open).
    func refreshAfterWake() {
        queue.async { [self] in
            guard currentRoute() == nil else { return }   // a dictation is in progress: its watchdog looks after it
            stopStream()
            dropPrepared()
            directBlockedUntil = 0
            prepareNow()
        }
    }

    /// Stops everything (the app is quitting).
    func shutdown() {
        queue.sync { [self] in
            stopStream()
            dropPrepared()
            removeListeners()
        }
    }

    // MARK: - Routing

    /// Stops sending audio to `take`, if it is the one receiving it.
    private func detach(_ take: Take) {
        routeLock.lock()
        if routedTake === take { routedTake = nil }
        routeLock.unlock()
    }

    /// Called whenever a take ends: with nobody listening, the microphone is closed, unless it is
    /// meant to stay open, in which case it keeps filling the pre-roll buffer.
    private func settle() {
        lingerWork?.cancel()
        lingerWork = nil
        let now = Uptime.now
        routeLock.lock()
        let idle = routedTake == nil
        // How much longer an open microphone should stay open with nobody dictating (nil: no limit).
        var remaining: TimeInterval? = 0
        switch standby {
        case .never:
            remaining = 0
        case .always:
            remaining = nil
        case .after(let seconds):
            let since = lastDictationEnded == 0 ? seconds : Double(now - lastDictationEnded) / 1_000_000_000
            remaining = max(0, seconds - since)
        }
        if let limited = remaining, heldOpenUntil > now {
            // A dictation is still being worked on: stay open at least until that is over.
            remaining = max(limited, Double(heldOpenUntil - now) / 1_000_000_000)
        }
        // Only the fast path stays open, never a Bluetooth microphone. And only `.always` opens a
        // closed microphone; the other cases merely keep an open one open.
        let stayOpen = stream != nil && (stream?.hal != nil || stream?.feed != nil) && remaining != 0
        let open = stream == nil && standby == .always
        // Marked under the lock, so a take beginning right now cannot adopt a stream that is about to stop.
        if idle, !stayOpen, !open { streamLive = false }
        routeLock.unlock()
        guard idle else { return }
        if open {
            startStream(for: nil)
        } else if !stayOpen {
            stopStream()
            return
        }
        if let remaining, remaining > 0 {
            let work = DispatchWorkItem { [weak self] in self?.settle() }
            lingerWork = work
            queue.asyncAfter(deadline: .now() + remaining + 0.01, execute: work)
        }
    }

    /// Any capture thread.
    private func deliver(_ samples: UnsafeBufferPointer<Float>, capturedAt: UInt64) {
        guard let base = samples.baseAddress, samples.count > 0 else { return }
        routeLock.lock()
        if delivered == 0 { streamFirstSample = capturedAt != 0 ? capturedAt : Uptime.now }
        let justOpened = gate.feed(samples)
        let open = gate.isOpen
        let silent = gate.gaveUp
        // Sound began where the silence ended, which is earlier than the moment it is noticed here.
        let soundBegan = justOpened
            ? streamFirstSample + UInt64(gate.deadSamples) * 1_000_000_000 / UInt64(SpeechEngine.sampleRate)
            : Uptime.now
        delivered += samples.count
        let take = routedTake
        if take == nil { ring.write(samples) }
        routeLock.unlock()
        guard let take else { return }
        take.append(samples, capturedAt: capturedAt)
        meter.push(base, count: samples.count)
        if open, take.markSoundStarted(at: soundBegan, stillSilent: silent) {
            DispatchQueue.main.async { [weak self] in self?.onSoundStarted?(take) }
        }
    }

    // MARK: - Preparing

    private func schedulePrepare(after delay: TimeInterval) {
        prepareWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.prepareNow() }
        prepareWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func prepareNow() {
        installSystemListeners()
        guard stream == nil else { return }
        if simulatedInput != nil {
            setFastPathReady(true)
            settle()
            return
        }
        guard AudioRecorder.forcedBackend != "engine", Uptime.now >= directBlockedUntil else {
            dropPrepared()
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if prepared != nil || !loggedUnpreparable { Log.info("Microphone not set up ahead: no microphone permission yet") }
            loggedUnpreparable = true
            dropPrepared()
            return
        }
        guard let device = resolveDevice() else {
            if !loggedUnpreparable { Log.info("Microphone not set up ahead: no input device found") }
            loggedUnpreparable = true
            dropPrepared()
            return
        }
        loggedUnpreparable = false
        guard !device.isWireless else {
            dropPrepared()
            return
        }
        if let prepared, let preparedDevice, preparedDevice.id == device.id,
           prepared.description.sampleRate == AudioDevices.nominalSampleRate(device.id) {
            preparedForUID = wantedUID
            setFastPathReady(true)
        } else {
            dropPrepared()
            do {
                let capture = try HALCapture.make(deviceID: device.id, queue: queue)
                prepared = capture
                preparedDevice = device
                preparedForUID = wantedUID
                listen(to: device.id)
                setFastPathReady(true)
                logReady(device, capture)
            } catch {
                Log.error("Could not prepare \(device.name): \(error.localizedDescription)")
            }
        }
        settle()
    }

    private func logReady(_ device: AudioDevices.Device, _ capture: HALCapture) {
        let description = capture.description
        Log.info("Microphone ready: \(device.name), \(Int(description.sampleRate)) Hz, \(description.channels) ch, "
            + "\(description.ioFrames)-frame blocks")
    }

    private func dropPrepared() {
        prepared?.dispose()
        prepared = nil
        preparedDevice = nil
        preparedForUID = nil
        setFastPathReady(false)
    }

    private func setFastPathReady(_ ready: Bool) {
        routeLock.lock()
        fastPathReady = ready
        routeLock.unlock()
    }

    private func resolveDevice() -> AudioDevices.Device? {
        if let wantedUID, let device = AudioDevices.device(forUID: wantedUID) { return device }
        return AudioDevices.defaultInputDevice()
    }

    // MARK: - Starting

    /// Opens the microphone. `take` is nil when it is opened only to stand by.
    private func startStream(for take: Take?, restarts: Int = 0, skipDirect: Bool = false) {
        if let samples = simulatedInput {
            startSimulated(samples)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            if let take { fail(take, CaptureError.microphoneAccessDenied) }
            return
        }
        stream = Stream(restarts: restarts)
        if !skipDirect, AudioRecorder.forcedBackend != "engine", Uptime.now >= directBlockedUntil, startDirect() {
            startWatchdog()
            return
        }
        // Standing by is only worth it on the fast path.
        guard take != nil || currentRoute() != nil else {
            stream = nil
            return
        }
        do {
            try startEngine()
            startWatchdog()
        } catch {
            stream = nil
            markStreamClosed()
            if let failed = take ?? currentRoute() { fail(failed, error) }
        }
    }

    /// The fast path: the prepared input unit, or a freshly built one if none is ready.
    private func startDirect() -> Bool {
        // A unit prepared for another microphone choice is of no use.
        if prepared != nil, preparedForUID != wantedUID { dropPrepared() }
        for attempt in 0..<2 {
            if prepared == nil {
                guard let device = resolveDevice(), !device.isWireless else { return false }
                do {
                    let capture = try HALCapture.make(deviceID: device.id, queue: queue)
                    prepared = capture
                    preparedDevice = device
                    preparedForUID = wantedUID
                    listen(to: device.id)
                    setFastPathReady(true)
                    logReady(device, capture)
                } catch {
                    Log.error("Fast capture unavailable: \(error.localizedDescription)")
                    return false
                }
            }
            guard let capture = prepared else { return false }
            capture.onSamples = { [weak self] samples, capturedAt in
                // Test switch: a fast path that starts but stays silent, to exercise the fallback.
                guard AudioRecorder.forcedBackend != "silent-direct" else { return }
                self?.deliver(samples, capturedAt: capturedAt)
            }
            markStreamOpening(backend: "direct")
            do {
                try capture.start()
                stream?.hal = capture
                return true
            } catch {
                // A unit prepared long ago can go stale (sleep, device reset): rebuild once.
                Log.error("Fast capture did not start (attempt \(attempt + 1)): \(error.localizedDescription)")
                markStreamClosed()
                capture.onSamples = nil
                dropPrepared()
            }
        }
        return false
    }

    private func startEngine() throws {
        let capture = EngineCapture()
        capture.onSamples = { [weak self] samples, capturedAt in self?.deliver(samples, capturedAt: capturedAt) }
        capture.onConfigurationChange = { [weak self, weak capture] in
            self?.queue.async {
                guard let self, let capture, self.stream?.engine === capture else { return }
                Log.info("Audio configuration changed, restarting capture")
                self.restartStream()
            }
        }
        let chosen = wantedUID.flatMap { AudioDevices.device(forUID: $0) }
        markStreamOpening(backend: "engine")
        do {
            try capture.start(deviceID: chosen?.id)
        } catch {
            markStreamClosed()
            throw error
        }
        stream?.engine = capture
    }

    private func startSimulated(_ samples: [Float]) {
        stream = Stream()
        routeLock.lock()
        gate = .open
        streamLive = true
        streamBackend = "simulated"
        delivered = 0
        routedTake?.noteCaptureStarted(backend: "simulated")
        routeLock.unlock()
        let started = Uptime.now
        var sent = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, !samples.isEmpty else { return }
            let elapsed = Double(Uptime.now - started) / 1_000_000_000
            let wanted = Int(elapsed * Double(SpeechEngine.sampleRate))
            guard wanted > sent else { return }
            // The clip repeats, so a hold longer than the clip keeps receiving audio.
            var chunk = [Float]()
            chunk.reserveCapacity(wanted - sent)
            while sent < wanted {
                let offset = sent % samples.count
                let length = min(wanted - sent, samples.count - offset)
                chunk.append(contentsOf: samples[offset..<(offset + length)])
                sent += length
            }
            chunk.withUnsafeBufferPointer { self.deliver($0, capturedAt: 0) }
        }
        timer.resume()
        stream?.feed = timer
    }

    /// About to start the hardware: from here on audio may arrive at any moment.
    private func markStreamOpening(backend: String) {
        routeLock.lock()
        gate = StartupGate()
        ring.clear()
        delivered = 0
        streamLive = true
        streamBackend = backend
        routedTake?.noteCaptureStarted(backend: backend)
        routeLock.unlock()
    }

    private func markStreamClosed() {
        routeLock.lock()
        streamLive = false
        routeLock.unlock()
    }

    private func currentRoute() -> Take? {
        routeLock.lock(); defer { routeLock.unlock() }
        return routedTake
    }

    // MARK: - Stopping and recovering

    /// Closes the microphone. Audio captured up to this moment still reaches the take receiving it.
    private func stopStream() {
        watchdog?.cancel()
        watchdog = nil
        markStreamClosed()
        guard let current = stream else { return }
        stream = nil
        if let hal = current.hal {
            hal.stop()
            hal.onSamples = nil
        }
        current.engine?.stop()
        current.engine?.onSamples = nil
        current.feed?.cancel()
    }

    private func fail(_ take: Take, _ error: Error) {
        Log.error("Capture failed: \(error.localizedDescription)")
        detach(take)
        take.seal()
        DispatchQueue.main.async { [weak self] in self?.onFailure?(take, error) }
    }

    /// Checks that audio keeps arriving. A microphone that stays silent or goes quiet mid-dictation
    /// (unplugged, format switched under us) is restarted, first on the fast path, then on the other.
    private func startWatchdog() {
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(400), repeating: .milliseconds(250), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.checkProgress() }
        timer.resume()
        watchdog = timer
    }

    private func checkProgress() {
        guard var current = stream, current.feed == nil else { return }
        routeLock.lock()
        let count = delivered
        routeLock.unlock()
        let now = Uptime.now
        if count > current.lastDelivered {
            current.lastDelivered = count
            current.lastProgress = now
            stream = current
            return
        }
        let silentFor = Uptime.milliseconds(from: current.lastProgress, to: now)
        // The fast path gets 0.4 s to produce its first audio; a stream that was flowing gets a second.
        let limit: Double = count > 0 ? 1000 : (current.hal != nil ? 380 : 3000)
        guard silentFor >= limit else { return }
        let take = currentRoute()
        if current.restarts >= 3 {
            stopStream()
            if let take { fail(take, CaptureError.engine("the microphone is not delivering audio")) }
            return
        }
        Log.error(String(format: "No audio for %.0f ms on the %@ path, restarting capture", silentFor,
                         current.hal != nil ? "direct" : "engine"))
        // Nothing at all from the fast path. The first time, the unit may simply have gone stale (it was
        // prepared before the Mac slept, say): try a fresh one. If that is silent too, use the other
        // path and leave the fast one alone for ten minutes. A stream that stalled later is rebuilt as it was.
        let giveUpOnDirect = current.hal != nil && count == 0 && current.restarts >= 1
        if giveUpOnDirect { directBlockedUntil = now + 600_000_000_000 }
        if giveUpOnDirect, take == nil {
            // Standing by with a microphone that will not start: stop trying until it is needed.
            stopStream()
            dropPrepared()
            return
        }
        restartStream(skipDirect: giveUpOnDirect)
    }

    /// Restarts capture for whatever is being recorded, keeping what has been recorded so far.
    private func restartStream(skipDirect: Bool = false) {
        let restarts = (stream?.restarts ?? 0) + 1
        stopStream()
        // A unit that stalled is not trusted again: the next start builds a new one.
        dropPrepared()
        startStream(for: currentRoute(), restarts: restarts, skipDirect: skipDirect)
    }

    // MARK: - Following device changes

    private func installSystemListeners() {
        guard !systemListenersInstalled else { return }
        systemListenersInstalled = true
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            addListener(object: AudioObjectID(kAudioObjectSystemObject), selector: selector, scope: kAudioObjectPropertyScopeGlobal)
        }
    }

    private func listen(to device: AudioDeviceID) {
        guard device != listenedDevice else { return }
        // Replace the listeners of the previous device.
        let system = AudioObjectID(kAudioObjectSystemObject)
        for entry in listeners where entry.object != system {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(entry.object, &address, queue, entry.block)
        }
        listeners.removeAll { $0.object != system }
        listenedDevice = device
        addListener(object: device, selector: kAudioDevicePropertyNominalSampleRate, scope: kAudioObjectPropertyScopeGlobal)
        addListener(object: device, selector: kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeInput)
        addListener(object: device, selector: kAudioDevicePropertyDeviceIsAlive, scope: kAudioObjectPropertyScopeGlobal)
    }

    private func addListener(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesChanged() }
        if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
            listeners.append((object, address, block))
        }
    }

    private func removeListeners() {
        for entry in listeners {
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(entry.object, &address, queue, entry.block)
        }
        listeners.removeAll()
        listenedDevice = 0
        systemListenersInstalled = false
    }

    /// Runs on `queue` (the listeners are registered with it).
    private func devicesChanged() {
        guard let current = stream else {
            // Idle: rebuild for whatever is current now, once things have settled.
            schedulePrepare(after: 0.5)
            return
        }
        // The microphone is open: move to the new one only if the one in use really changed.
        guard let hal = current.hal else { return }   // the engine path reports its own changes
        let device = resolveDevice()
        let same = device?.id == hal.description.deviceID
            && AudioDevices.nominalSampleRate(hal.description.deviceID) == hal.description.sampleRate
        guard !same else { return }
        Log.info("Microphone changed while open, restarting capture")
        let restarts = current.restarts
        stopStream()
        dropPrepared()
        let take = currentRoute()
        if take != nil {
            startStream(for: take, restarts: restarts)
        } else {
            // It was only standing by: prepare for the new microphone, which also resumes standing by if wanted.
            schedulePrepare(after: 0.5)
        }
    }
}
