import SwiftUI

/// First-run setup: two permissions, the speech model, and a place to try it.
struct OnboardingView: View {
    @Environment(AppState.self) private var state
    @State private var sample = ""
    @FocusState private var sampleFocused: Bool

    var body: some View {
        @Bindable var settings = state.settings
        let _ = state.downloads.completedCount
        let model = SpeechModel.model(id: settings.modelID)
        let modelReady = SpeechModel.bestInstalled(preferred: settings.modelID) != nil
        let ready = state.permissions.allGranted && modelReady

        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 9) {
                    NabraMark(size: 64)
                    Text("Welcome to Nabra")
                        .font(.system(size: 28, weight: .bold))
                    Text("Hold a key, speak, and your words appear wherever you are typing.\nArabic, English, or both in one sentence. Nothing leaves this Mac.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 9) {
                    SetupStep(number: 1, title: "Microphone",
                              detail: "Records only while you hold the dictation key.",
                              done: state.permissions.microphoneGranted) {
                        Button(state.permissions.microphone == .notDetermined ? "Allow" : "Open Settings") {
                            state.permissions.requestMicrophone()
                        }
                    }
                    SetupStep(number: 2, title: "Accessibility",
                              detail: "Lets Nabra notice your dictation key and type into other apps. In the list that opens, switch Nabra on.",
                              done: state.permissions.accessibility) {
                        Button("Open Settings") { state.permissions.requestAccessibility() }
                    }
                    SetupStep(number: 3, title: "Speech model",
                              detail: modelDetail(model, ready: modelReady),
                              done: modelReady) {
                        if let progress = state.downloads.progress[model.id] {
                            HStack(spacing: 8) {
                                ProgressView(value: progress).frame(width: 110)
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Button("Download") { state.downloads.download(model) }
                        }
                    }
                }

                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Your dictation key")
                                .font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Picker("", selection: $settings.hotkey) {
                                ForEach(Hotkey.presets, id: \.self) { hotkey in
                                    Text(hotkey.longName).tag(hotkey)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                        HStack(alignment: .top, spacing: 14) {
                            KeyCap(symbol: settings.hotkey.keyCapSymbol, label: "hold", size: 46)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(ready ? "Try it: click in the box, hold \(settings.hotkey.displayName), and say something."
                                        : "Finish the steps above, then try it here.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.secondary)
                                TextEditor(text: $sample)
                                    .font(.system(size: 13.5))
                                    .scrollContentBackground(.hidden)
                                    .padding(8)
                                    .frame(height: 76)
                                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(sampleFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1))
                                    .focused($sampleFocused)
                                    .disabled(!ready)
                                    .environment(\.layoutDirection, TextScript.isRightToLeft(sample) ? .rightToLeft : .leftToRight)
                            }
                        }
                    }
                }

                Button {
                    settings.onboardingCompleted = true
                } label: {
                    Text(ready ? "Start Using Nabra" : "Complete the steps above")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 240, height: 22)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!ready)
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 10)
            }
            .padding(.horizontal, 40)
            .padding(.top, 34)
            .padding(.bottom, 24)
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.top)
        .scrollContentBackground(.hidden)
        .onChange(of: ready) { _, isReady in
            if isReady {
                state.warmUp()
                sampleFocused = true
            }
        }
    }

    private func modelDetail(_ model: SpeechModel, ready: Bool) -> String {
        if ready { return "Installed. Runs on this Mac's graphics chip." }
        if let error = state.downloads.errors[model.id] { return error }
        return "A one-time \(model.sizeDescription) download. After that Nabra works offline."
    }
}

private struct SetupStep<Action: View>: View {
    var number: Int
    var title: String
    var detail: String
    var done: Bool
    @ViewBuilder var action: Action

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 13) {
                ZStack {
                    Circle()
                        .fill(done ? Color.green.opacity(0.16) : Color.primary.opacity(0.07))
                        .frame(width: 30, height: 30)
                    if done {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text("\(number)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if !done {
                    action
                        .controlSize(.regular)
                }
            }
        }
    }
}
