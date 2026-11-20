import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.needsSetup {
                OnboardingView()
            } else {
                MainView()
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}

struct MainView: View {
    @Environment(AppState.self) private var state
    @Environment(Navigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: Binding(get: { navigation.section }, set: { navigation.section = $0 ?? .home })) {
                ForEach(Navigation.Section.allCases) { section in
                    Label(section.title, systemImage: section.symbol)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom) { SidebarStatus() }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            switch navigation.section {
            case .home: HomeView()
            case .history: HistoryView()
            case .dictionary: DictionaryView()
            case .settings: SettingsView()
            }
        }
    }
}

/// Bottom of the sidebar: is Nabra ready, and which key starts it.
private struct SidebarStatus: View {
    @Environment(AppState.self) private var state

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text("Hold \(state.settings.hotkey.displayName) to dictate")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var title: String {
        if AppState.isDemo { return "Ready" }
        if state.dictation.phase == .listening { return "Listening" }
        if !state.hotkeyActive { return "Key not active" }
        switch state.transcription.state {
        case .loading: return "Warming up"
        case .failed: return "Model problem"
        case .missingModel: return "No speech model"
        default: return "Ready"
        }
    }

    private var color: Color {
        if AppState.isDemo { return .green }
        if state.dictation.phase == .listening { return .red }
        if !state.hotkeyActive { return .orange }
        switch state.transcription.state {
        case .failed, .missingModel: return .orange
        case .loading: return .yellow
        default: return .green
        }
    }
}
