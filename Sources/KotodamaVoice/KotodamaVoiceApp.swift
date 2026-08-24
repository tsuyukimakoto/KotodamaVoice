import AppKit
import KotodamaCore
import SwiftUI

@main
struct KotodamaVoiceApp: App {
    @State private var runtime: AppRuntime
    @State private var store: PipelineStore

    init() {
        let defaults: UserDefaults
        #if DEBUG
            if ProcessInfo.processInfo.environment["KOTODAMA_UI_TESTING"] == "1" {
                defaults = UserDefaults(
                    suiteName: "KotodamaVoiceUITests-\(ProcessInfo.processInfo.processIdentifier)"
                )!
            } else {
                defaults = .standard
            }
        #else
            defaults = .standard
        #endif
        let runtime = AppRuntime(defaults: defaults)
        _runtime = State(initialValue: runtime)
        _store = State(initialValue: runtime.pipelineStore)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(runtime: runtime)
                .environment(store)
                .environment(runtime)
        } label: {
            Label(store.state.title, systemImage: store.state.systemImage)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environment(store)
                .environment(runtime)
        }

        Window("モデル", id: "models") {
            ModelsView()
                .environment(runtime)
        }
        .defaultSize(width: 620, height: 420)

        Window("Runtime Monitor", id: "runtime-monitor") {
            RuntimeMonitorView()
                .environment(runtime)
        }
        .defaultSize(width: 640, height: 420)
    }
}

private struct MenuBarContent: View {
    @Environment(PipelineStore.self) private var store
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    let runtime: AppRuntime

    var body: some View {
        Text(store.state.title)
        if let operationError = runtime.operationError {
            Text(operationError)
        }
        Divider()
        Button(store.state == .recording ? "録音を停止" : "録音を開始") {
            runtime.toggleRecording()
        }
        .disabled(store.state.isBusy && store.state != .recording)
        Divider()
        Button("設定…") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)
        Button("モデル…") {
            openWindow(id: "models")
        }
        Button("Runtime Monitor…") {
            openWindow(id: "runtime-monitor")
        }
        Divider()
        Button("終了") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

}

private extension PipelineState {
    var title: String {
        switch self {
        case .ready:
            "待機中"
        case .recording:
            "録音中"
        case .transcribing:
            "文字起こし中"
        case .formatting:
            "整形中"
        case .outputting:
            "出力中"
        case .cancelling:
            "キャンセル中"
        case .failed:
            "エラー"
        }
    }

    var systemImage: String {
        switch self {
        case .ready:
            "waveform"
        case .recording:
            "record.circle.fill"
        case .transcribing, .formatting, .outputting, .cancelling:
            "waveform.badge.magnifyingglass"
        case .failed:
            "exclamationmark.triangle"
        }
    }

    var isBusy: Bool {
        switch self {
        case .transcribing, .formatting, .outputting, .cancelling:
            true
        case .ready, .recording, .failed:
            false
        }
    }
}
