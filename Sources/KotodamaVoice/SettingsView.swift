import AppKit
import KotodamaCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        TabView {
            GeneralSettingsView(
                runtime: runtime,
                openModels: { openWindow(id: "models") },
                openRuntimeMonitor: { openWindow(id: "runtime-monitor") }
            )
            .tabItem {
                Label("General", systemImage: "gearshape")
                    .accessibilityIdentifier("general-settings")
            }

            PlaceholderSettingsView(
                title: "Speech",
                detail: "文字起こしEngineとモデルを設定します。"
            )
            .tabItem {
                Label("Speech", systemImage: "waveform")
                    .accessibilityIdentifier("speech-settings")
            }

            FormattingSettingsView(settings: runtime.formatterSettings)
            .tabItem {
                Label("Formatting", systemImage: "text.alignleft")
                    .accessibilityIdentifier("formatting-settings")
            }

            OutputSettingsView(settings: runtime.outputSettings)
            .tabItem {
                Label("Output", systemImage: "clipboard")
                    .accessibilityIdentifier("output-settings")
            }

            PlaceholderSettingsView(
                title: "Models",
                detail: "内蔵Engineのモデルを管理します。"
            )
            .tabItem {
                Label("Models", systemImage: "shippingbox")
                    .accessibilityIdentifier("models-settings")
            }
        }
        .padding(20)
        .frame(width: 620, height: 420)
    }
}

private struct OutputSettingsView: View {
    let settings: OutputSettingsStore
    @State private var showsAccessibilityExplanation = false

    var body: some View {
        Form {
            Section("出力方式") {
                Picker(
                    "出力方式",
                    selection: Binding(
                        get: { settings.mode },
                        set: { mode in select(mode) }
                    )
                ) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("output-mode-picker")

                LabeledContent("現在の出力") {
                    Text(settings.mode.displayName)
                        .accessibilityIdentifier("output-mode-value")
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.permissionResult == .permissionRequired {
                Section("Accessibility権限") {
                    Text("システム設定でKotodamaVoiceのAccessibilityを許可してください。許可されるまでClipboardを使用します。")
                        .accessibilityIdentifier("accessibility-permission-required")
                    Button("権限を再確認") {
                        settings.recheckAutoInsertPermission()
                    }
                    .accessibilityIdentifier("accessibility-permission-recheck")
                }
            }

            #if DEBUG
                if ProcessInfo.processInfo.environment["KOTODAMA_UI_TESTING"] == "1" {
                    Text("\(settings.permissionPromptRequestCount)")
                        .accessibilityIdentifier("accessibility-prompt-count")
                }
            #endif
        }
        .formStyle(.grouped)
        .alert(
            "Auto Insertを有効にしますか？",
            isPresented: $showsAccessibilityExplanation
        ) {
            Button("キャンセル", role: .cancel) {}
            Button("許可を要求") {
                settings.requestAutoInsertPermission()
            }
        } message: {
            Text("録音開始時に選択されていた入力欄へ結果を挿入するため、macOSのAccessibility権限が必要です。音声入力の内容は権限確認に使用しません。")
        }
    }

    private var detail: String {
        switch settings.mode {
        case .clipboard:
            "結果をClipboardへコピーします。Accessibility権限は使用しません。"
        case .autoInsert:
            "録音開始時に選択されていた入力欄を再確認して結果を挿入します。"
        }
    }

    private func select(_ mode: OutputMode) {
        switch mode {
        case .clipboard:
            settings.selectClipboard()
        case .autoInsert:
            showsAccessibilityExplanation = true
        }
    }
}

private struct FormattingSettingsView: View {
    let settings: FormatterSettingsStore
    @State private var showsOverwriteConfirmation = false

    var body: some View {
        Form {
            Section("文章整形") {
                Picker(
                    "Formatter",
                    selection: Binding(
                        get: { settings.engine },
                        set: { settings.setEngine($0) }
                    )
                ) {
                    ForEach(FormattingEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("formatter-engine-picker")

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("formatter-engine-detail")
            }

            Section("Prompt") {
                Picker(
                    "使用するPrompt",
                    selection: Binding(
                        get: { settings.promptSource },
                        set: { settings.setPromptSource($0) }
                    )
                ) {
                    ForEach(FormattingPromptSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("prompt-source-picker")

                switch settings.promptSource {
                case .defaultPrompt:
                    LabeledContent(
                        "Resource",
                        value: "\(settings.defaultPrompt.identifier) v\(settings.defaultPrompt.version)"
                    )
                    .accessibilityIdentifier("default-prompt-version")
                    Text(settings.defaultPrompt.text)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("default-prompt-text")
                case .custom:
                    TextEditor(
                        text: Binding(
                            get: { settings.customPrompt },
                            set: { settings.setCustomPrompt($0) }
                        )
                    )
                    .font(.body)
                    .frame(minHeight: 110)
                    .accessibilityIdentifier("custom-prompt-editor")
                }

                Button("DefaultをCustomへ読み込む") {
                    if settings.importDefaultIntoCustom() == .requiresConfirmation {
                        showsOverwriteConfirmation = true
                    }
                }
                .accessibilityIdentifier("default-prompt-import-button")
            }
        }
        .formStyle(.grouped)
        .alert(
            "Custom Promptを上書きしますか？",
            isPresented: $showsOverwriteConfirmation
        ) {
            Button("キャンセル", role: .cancel) {}
            Button("上書き", role: .destructive) {
                _ = settings.importDefaultIntoCustom(overwriteConfirmed: true)
            }
        } message: {
            Text("現在のCustom Promptは失われます。")
        }
    }

    private var detail: String {
        switch settings.engine {
        case .off:
            "文字起こし結果を変更せず、そのまま出力します。"
        case .builtIn:
            "端末内のFormatter Workerで文章を整えます。"
        case .external:
            "設定した外部Formatterへ文字起こし結果を送信します。"
        }
    }
}

private struct GeneralSettingsView: View {
    let runtime: AppRuntime
    let openModels: () -> Void
    let openRuntimeMonitor: () -> Void

    var body: some View {
        Form {
            Section("アプリ") {
                LabeledContent("現在の状態", value: "待機中")
                LabeledContent("起動方式") {
                    Text(
                        NSApplication.shared.activationPolicy() == .accessory
                            ? "accessory"
                            : "regular"
                    )
                    .accessibilityIdentifier("activation-policy")
                }
                Toggle(
                    "ログイン時に起動",
                    isOn: Binding(
                        get: { runtime.launchAtLoginSettings.isEnabled },
                        set: { isEnabled in
                            runtime.launchAtLoginSettings.setEnabled(isEnabled)
                        }
                    )
                )
                .accessibilityIdentifier("launch-at-login-toggle")
                if runtime.launchAtLoginSettings.status == .requiresApproval {
                    HStack {
                        Text("システム設定で起動を許可してください。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("ログイン項目を開く") {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
                if let errorMessage = runtime.launchAtLoginSettings.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("launch-at-login-error")
                }
            }

            Section("グローバルショートカット") {
                LabeledContent("録音の開始・停止") {
                    ShortcutRecorder(
                        descriptor: runtime.hotKeySettings.descriptor,
                        onChange: runtime.hotKeySettings.update
                    )
                    .accessibilityIdentifier("hotkey-recorder")
                }
                Text("欄をクリックし、修飾キーと任意のキーを押してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = runtime.hotKeySettings.registrationError {
                    Text(message(for: error))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("hotkey-registration-error")
                }
            }

            Section("管理") {
                Button("モデルを管理…", action: openModels)
                    .accessibilityIdentifier("models-open-button")
                Button("Runtime Monitorを開く…", action: openRuntimeMonitor)
                    .accessibilityIdentifier("runtime-open-button")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            runtime.launchAtLoginSettings.refresh()
        }
    }

    private func message(for error: HotKeyRegistrationError) -> String {
        switch error {
        case .conflict:
            "このショートカットは別のアプリが使用しています。以前の設定を継続します。"
        case .systemError:
            "ショートカットを登録できませんでした。以前の設定を継続します。"
        }
    }
}

private struct PlaceholderSettingsView: View {
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: "slider.horizontal.3",
            description: Text(detail)
        )
    }
}
