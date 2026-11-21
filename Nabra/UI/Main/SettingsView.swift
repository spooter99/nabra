import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var devices: [AudioDevices.Device] = []
    @State private var storage = ""
    @State private var confirmingClear = false

    var body: some View {
        @Bindable var settings = state.settings
        let _ = state.downloads.completedCount

        Form {
            Section {
                LabeledContent("Dictation key") {
                    ShortcutField(hotkey: $settings.hotkey, other: settings.scribeHotkey, otherName: "the Scribe key",
                                  presets: Hotkey.presets)
                }
                Toggle("Double-tap for hands-free", isOn: $settings.handsFreeEnabled)
                if settings.hotkey.isFunctionKey {
                    Label("In System Settings › Keyboard, set “Press 🌐 key to” to “Do Nothing”, or macOS will also react to the key.",
                          systemImage: "info.circle")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else if settings.hotkey == .eitherOption || settings.hotkey == .leftOption {
                    Text("Shortcuts such as ⌥← and ⌥⌫ keep working: dictation only starts when the key is held on its own. The microphone is switched on the moment the key goes down. With the left Option key the indicator appears a fraction of a second later, once it is clear you are not typing a shortcut.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Shortcut")
            }

            Section {
                Toggle("Scribe", isOn: Binding(
                    get: { settings.scribeEnabled },
                    set: { on in
                        settings.scribeEnabled = on
                        // Turning Scribe on is what downloads its model; nothing is fetched before that.
                        let files = WriterModel.current.downloads
                        if !on {
                            files.forEach(state.downloads.cancel)
                        } else if state.writer.helperURL != nil {
                            files.forEach(state.downloads.download)
                        }
                    }))
                if !settings.scribeEnabled {
                    Text("Hold a second key and your words come back written up, or written for you. Turning Scribe on downloads its model (\(WriterModel.current.sizeDescription)) once. While it is off, nothing is downloaded, loaded or run for it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    if WriterModel.current.isInstalled {
                        WriterModelRow(model: WriterModel.current)
                    }
                }
                if settings.scribeEnabled {
                    LabeledContent("Scribe key") {
                        ShortcutField(hotkey: $settings.scribeHotkey, other: settings.hotkey, otherName: "the dictation key",
                                      presets: Hotkey.scribePresets)
                    }
                    if settings.scribeHotkey.overlaps(settings.hotkey) {
                        Label("This is also the dictation key. Pick another one for Scribe.", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.orange)
                    }
                    WriterModelRow(model: WriterModel.current)
                    Toggle("Let Scribe see the app and the text before the cursor", isOn: $settings.scribeUsesContext)
                    Text("Hold the Scribe key and talk. Your words come back written up: grammar fixed, self-corrections applied, the way you would write it. Ask for something (“write an email to Sara saying the meeting moved to Thursday”) and you get that text. It runs on a small language model on this Mac, in Arabic and English.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Scribe")
            }

            Section {
                Picker("Language", selection: $settings.languageMode) {
                    ForEach(LanguageMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.languageMode.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Language")
            }

            Section {
                Picker("Clean-up", selection: $settings.cleanupMode) {
                    ForEach(CleanupMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(cleanupDetail(settings.cleanupMode))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Toggle("Remove “um” and “uh”", isOn: $settings.removeFillers)
                Toggle("Say “new line” or “new paragraph” to break lines", isOn: $settings.voiceCommands)
                Toggle("Turn spoken lists into lists (“one, … two, …”, or “here is the list: …”)", isOn: $settings.formatLists)
                Toggle("Break long dictations into paragraphs", isOn: $settings.formatParagraphs)
                Toggle("Learn spellings from my corrections", isOn: $settings.learnFromCorrections)
                Toggle("Add spaces and adjust capitals to fit the surrounding text", isOn: $settings.smartSpacing)
            } header: {
                Text("Text")
            }

            Section {
                ForEach(SpeechModel.all) { model in
                    ModelRow(model: model)
                }
                Picker("Keep ready in memory", selection: $settings.modelIdleMinutes) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("30 minutes").tag(30)
                    Text("1 hour").tag(60)
                    Text("Always").tag(0)
                }
                Text("The model reloads in about a tenth of a second when you press the key, so a short time keeps Nabra light.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Speech model")
            } footer: {
                Text("Cohere Transcribe Arabic, running entirely on this Mac. The three sizes are the same model at different compression.")
            }

            Section {
                Toggle("Mute much quieter voices around me", isOn: $settings.ignoreBackgroundVoices)
                if settings.ignoreBackgroundVoices {
                    Text("Speech far quieter than yours is cut out before transcription. If you speak very softly or turn away from the microphone, your own words can be cut too.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Picker("Microphone", selection: $settings.inputDeviceUID) {
                    Text("System default").tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                Picker("Microphone is on", selection: $settings.microphoneReadiness) {
                    ForEach(MicrophoneReadiness.allCases) { readiness in
                        Text(readiness.title).tag(readiness)
                    }
                }
                Text(settings.microphoneReadiness.detail
                    + (settings.microphoneReadiness == .onDemand ? "" : " Bluetooth microphones are still switched on only while you dictate."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Picker("Insert text by", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                Text(settings.insertionMethod.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                if settings.insertionMethod == .paste {
                    Toggle("Put my clipboard back after pasting", isOn: $settings.restoreClipboard)
                }
                Toggle("Play sounds", isOn: $settings.playSounds)
                if settings.playSounds {
                    LabeledContent("Sound volume") {
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                            Slider(value: $settings.soundVolume, in: 0.1...1) { editing in
                                if !editing { state.dictation.previewSound() }
                            }
                            .frame(width: 170)
                            Image(systemName: "speaker.wave.2.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Recording indicator", selection: $settings.indicatorPosition) {
                    ForEach(IndicatorPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                Toggle("Show the words as I speak", isOn: $settings.showLiveText)
            } header: {
                Text("Input and output")
            }

            Section {
                Toggle("Save dictations to History", isOn: $settings.saveHistory)
                Picker("Keep recordings", selection: $settings.audioRetention) {
                    ForEach(AudioRetention.allCases) { retention in
                        Text(retention.title).tag(retention)
                    }
                }
                LabeledContent("Storage used", value: storage)
                Button("Delete All History…", role: .destructive) { confirmingClear = true }
            } header: {
                Text("Privacy and storage")
            } footer: {
                Text("Audio and text never leave this Mac. Recordings let you replay a dictation; the text is kept until you delete it.")
            }

            Section {
                Toggle("Open Nabra at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        if !LaunchAtLogin.set(enabled) { launchAtLogin = LaunchAtLogin.isEnabled }
                    }
                PermissionLine(title: "Microphone", granted: state.permissions.microphoneGranted) {
                    state.permissions.requestMicrophone()
                }
                PermissionLine(title: "Accessibility", granted: state.permissions.accessibility) {
                    state.permissions.requestAccessibility()
                }
            } header: {
                Text("General")
            }

            Section {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                LabeledContent("Speech model", value: "Cohere Transcribe Arabic (Apache-2.0)")
                LabeledContent("Engine", value: "transcribe.cpp and ggml (MIT)")
                Link("Source code and documentation", destination: URL(string: "https://github.com/spooter99/nabra")!)
            } header: {
                Text("About")
            } footer: {
                Text("Nabra is open source under the Apache License 2.0. Audio and text never leave this Mac.")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .navigationTitle("Settings")
        .onAppear {
            devices = AudioDevices.inputDevices()
            launchAtLogin = LaunchAtLogin.isEnabled
            refreshStorage()
        }
        .onChange(of: settings.modelID) { _, _ in state.warmUp() }
        .onChange(of: settings.audioRetention) { _, retention in
            if let days = retention.days { state.history.pruneAudio(olderThanDays: days) }
            refreshStorage()
        }
        .confirmationDialog("Delete every saved dictation?", isPresented: $confirmingClear) {
            Button("Delete All", role: .destructive) {
                state.history.deleteAll()
                refreshStorage()
            }
        } message: {
            Text("This removes all text and audio saved by Nabra. Your dictionary is kept.")
        }
    }

    private func cleanupDetail(_ mode: CleanupMode) -> String {
        if mode != .off, !state.cleanup.isAvailable {
            return mode.detail + " Needs macOS 26 with Apple Intelligence switched on; until then text is inserted as spoken."
        }
        return mode.detail
    }

    private func refreshStorage() {
        DispatchQueue.global(qos: .utility).async {
            func size(_ url: URL) -> Int64 {
                let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                var total: Int64 = 0
                while let file = files?.nextObject() as? URL {
                    total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
                return total
            }
            let recordings = size(AppPaths.audioDirectory)
            let models = size(AppPaths.modelsDirectory)
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let text = "\(formatter.string(fromByteCount: models)) models, \(formatter.string(fromByteCount: recordings)) recordings"
            DispatchQueue.main.async { storage = text }
        }
    }
}

private struct ModelRow: View {
    @Environment(AppState.self) private var state
    var model: SpeechModel

    var body: some View {
        let installed = model.isInstalled
        let selected = state.settings.modelID == model.id
        let progress = state.downloads.progress[model.id]

        HStack(spacing: 10) {
            Image(systemName: selected && installed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected && installed ? Color.accentColor : Color.secondary.opacity(0.5))
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.title).fontWeight(.medium)
                    Text(model.sizeDescription).foregroundStyle(.secondary).font(.system(size: 11.5))
                }
                Text(state.downloads.errors[model.id] ?? model.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(state.downloads.errors[model.id] == nil ? Color.secondary : Color.red)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button("Cancel") { state.downloads.cancel(model) }
                    .controlSize(.small)
            } else if installed {
                if !selected {
                    Button("Use") { state.settings.modelID = model.id }
                        .controlSize(.small)
                    Button("Delete") {
                        state.downloads.delete(model)
                        state.transcription.refreshInstalledState()
                    }
                    .controlSize(.small)
                } else {
                    Text("In use")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
            } else {
                Button("Download") { state.downloads.download(model) }
                    .controlSize(.small)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Scribe's writing model: download, progress, or ready.
private struct WriterModelRow: View {
    @Environment(AppState.self) private var state
    var model: WriterModel

    var body: some View {
        let download = model.download
        let progress = state.downloads.progress[download.id]
        let installed = model.isFullyInstalled
        HStack(spacing: 10) {
            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(installed ? Color.accentColor : Color.secondary)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.title).fontWeight(.medium)
                    Text(model.sizeDescription).foregroundStyle(.secondary).font(.system(size: 11.5))
                }
                Text(state.downloads.errors[download.id] ?? (installed ? "Ready. It runs only while you use Scribe." : model.detail))
                    .font(.system(size: 11.5))
                    .foregroundStyle(state.downloads.errors[download.id] == nil ? Color.secondary : Color.red)
            }
            Spacer()
            if let progress {
                ProgressView(value: progress).frame(width: 90)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
                Button("Cancel") {
                    // Scribe without its model would do nothing: cancelling switches it off.
                    model.downloads.forEach(state.downloads.cancel)
                    state.settings.scribeEnabled = false
                }
                .controlSize(.small)
            } else if installed {
                Button("Delete") {
                    model.downloads.forEach(state.downloads.delete)
                    state.settings.scribeEnabled = false
                }
                .controlSize(.small)
            } else if state.writer.helperURL == nil {
                Text("Not included in this build").font(.system(size: 11.5)).foregroundStyle(.secondary)
            } else {
                Button("Download") { model.downloads.forEach(state.downloads.download) }
                    .controlSize(.small)
            }
        }
    }
}

private struct PermissionLine: View {
    var title: String
    var granted: Bool
    var fix: () -> Void

    var body: some View {
        LabeledContent(title) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.system(size: 12))
            } else {
                Button("Allow…", action: fix)
                    .controlSize(.small)
            }
        }
    }
}
