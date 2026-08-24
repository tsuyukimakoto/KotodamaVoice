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

            SpeechSettingsView(
                settings: runtime.speechSettings,
                externalSettings: runtime.externalEngineSettings
            )
            .tabItem {
                Label("Speech", systemImage: "waveform")
                    .accessibilityIdentifier("speech-settings")
            }

            FormattingSettingsView(
                settings: runtime.formatterSettings,
                externalSettings: runtime.externalEngineSettings
            )
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
        .frame(width: 680, height: 560)
    }
}

private struct SpeechSettingsView: View {
    let settings: SpeechSettingsStore
    let externalSettings: ExternalEngineSettingsStore

    var body: some View {
        Form {
            Section("文字起こし") {
                Picker(
                    "Speech Engine",
                    selection: Binding(
                        get: { settings.engine },
                        set: { settings.setEngine($0) }
                    )
                ) {
                    ForEach(SpeechEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("speech-engine-picker")

                Text(
                    settings.engine == .builtIn
                        ? "端末内のSpeech Workerで文字起こしします。"
                        : "設定した外部Speech Endpointへ録音音声を送信します。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if settings.engine == .external {
                ExternalEngineEditor(
                    purpose: .speech,
                    settings: externalSettings
                )
            }
        }
        .formStyle(.grouped)
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
    let externalSettings: ExternalEngineSettingsStore
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

            if settings.engine == .external {
                ExternalEngineEditor(
                    purpose: .formatter,
                    settings: externalSettings
                )
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

private struct ExternalEngineEditor: View {
    let purpose: ExternalEndpointPurpose
    let settings: ExternalEngineSettingsStore

    @State private var configurationID: UUID
    @State private var kind: ExternalEngineKind
    @State private var endpoint: String
    @State private var model: String
    @State private var timeout: String
    @State private var apiKey = ""
    @State private var pendingConfiguration: ExternalEngineConfiguration?
    @State private var confirmationRequirements:
        Set<ExternalEndpointConfirmationRequirement> = []
    @State private var showsConfirmation = false
    @State private var statusMessage: String?
    @State private var isTesting = false

    init(
        purpose: ExternalEndpointPurpose,
        settings: ExternalEngineSettingsStore
    ) {
        self.purpose = purpose
        self.settings = settings
        let existing = settings.configuration(for: purpose)
        _configurationID = State(initialValue: existing?.id ?? UUID())
        _kind = State(
            initialValue: existing?.kind ?? purpose.defaultEngineKind
        )
        _endpoint = State(
            initialValue: existing?.endpointURL.absoluteString ?? ""
        )
        _model = State(initialValue: existing?.model ?? "")
        _timeout = State(
            initialValue: String(existing?.timeout ?? 60)
        )
    }

    var body: some View {
        Section("外部Engine") {
            Picker("契約", selection: $kind) {
                ForEach(purpose.engineKinds, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .accessibilityIdentifier("external-engine-kind")

            TextField("Endpoint URL", text: $endpoint)
                .accessibilityIdentifier("external-endpoint")
            if kind.requiresModel {
                TextField("モデル", text: $model)
                    .accessibilityIdentifier("external-model")
            }
            TextField("Timeout（秒）", text: $timeout)
                .accessibilityIdentifier("external-timeout")
            SecureField("API Key（変更時のみ入力）", text: $apiKey)
                .accessibilityIdentifier("external-api-key")

            Text(payloadExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("保存", action: prepareSave)
                    .accessibilityIdentifier("external-save")
                Button("接続テスト", action: testConnection)
                    .disabled(isTesting || settings.configuration(for: purpose) == nil)
                    .accessibilityIdentifier("external-connection-test")
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("external-status")
            }
        }
        .alert(
            "外部Endpointへの送信を許可しますか？",
            isPresented: $showsConfirmation
        ) {
            Button("キャンセル", role: .cancel) {
                pendingConfiguration = nil
            }
            Button("許可して保存") {
                savePendingConfiguration()
            }
        } message: {
            Text(confirmationExplanation)
        }
    }

    private var payloadExplanation: String {
        switch purpose {
        case .speech:
            "外部Endpointを使う場合は録音音声を送信します。"
        case .formatter:
            "外部Endpointを使う場合は文字起こし結果とPromptを送信します。"
        }
    }

    private var confirmationExplanation: String {
        var messages = [payloadExplanation]
        if confirmationRequirements.contains(.unencryptedHTTP) {
            messages.append("この接続は平文HTTPで暗号化されません。")
        }
        return messages.joined(separator: "\n")
    }

    private func prepareSave() {
        do {
            guard let endpointURL = URL(string: endpoint),
                let timeoutValue = TimeInterval(timeout),
                timeoutValue > 0,
                !kind.requiresModel || !model.isEmpty
            else {
                statusMessage = "Endpoint、モデル、Timeoutを確認してください"
                return
            }
            let assessment = try ExternalEndpointPolicy.assess(
                endpointURL,
                purpose: purpose
            )
            confirmationRequirements = assessment.requiredConfirmations
            pendingConfiguration = ExternalEngineConfiguration(
                id: configurationID,
                kind: kind,
                endpointURL: endpointURL,
                model: model,
                timeout: timeoutValue,
                acceptedConfirmations: assessment.requiredConfirmations
            )
            if assessment.requiredConfirmations.isEmpty {
                savePendingConfiguration()
            } else {
                showsConfirmation = true
            }
        } catch {
            statusMessage = "HTTPまたはHTTPSのEndpointを入力してください"
        }
    }

    private func savePendingConfiguration() {
        guard let pendingConfiguration else { return }
        do {
            try settings.save(
                pendingConfiguration,
                apiKey: apiKey.isEmpty ? nil : apiKey
            )
            apiKey = ""
            self.pendingConfiguration = nil
            statusMessage = "保存しました"
        } catch {
            statusMessage = "設定を保存できませんでした"
        }
    }

    private func testConnection() {
        guard let configuration = settings.configuration(for: purpose) else {
            statusMessage = "先に設定を保存してください"
            return
        }
        isTesting = true
        statusMessage = "確認中"
        Task {
            do {
                let key = try settings.apiKey(for: configuration.id)
                let result = await ExternalEngineConnectionTester().test(
                    try connection(configuration: configuration, apiKey: key)
                )
                statusMessage = result == .ready
                    ? "接続できました"
                    : "Endpointの契約を確認できませんでした"
            } catch {
                statusMessage = "接続を確認できませんでした"
            }
            isTesting = false
        }
    }
}

private extension ExternalEndpointPurpose {
    var engineKinds: [ExternalEngineKind] {
        ExternalEngineKind.allCases.filter { $0.purpose == self }
    }

    var defaultEngineKind: ExternalEngineKind {
        switch self {
        case .speech: .openAIAudioTranscriptions
        case .formatter: .responses
        }
    }
}

private extension ExternalEngineKind {
    var displayName: String {
        switch self {
        case .openAIAudioTranscriptions: "OpenAI Audio Transcriptions"
        case .whisperCppInference: "whisper.cpp /inference"
        case .responses: "OpenAI Responses / LM Studio"
        case .chatCompletions: "Chat Completions / llama-server"
        }
    }

    var requiresModel: Bool {
        self != .whisperCppInference
    }
}

private func connection(
    configuration: ExternalEngineConfiguration,
    apiKey: String?
) throws -> ExternalEngineConnection {
    let confirmation = configuration.acceptedConfirmations.isEmpty
        ? nil
        : ExternalEndpointConfirmation(
            endpoint: configuration.endpointURL,
            accepted: configuration.acceptedConfirmations
        )
    switch configuration.kind {
    case .openAIAudioTranscriptions:
        return .openAIAudioTranscriptions(
            OpenAIAudioTranscriptionsAdapter(
                endpointURL: configuration.endpointURL,
                model: configuration.model,
                apiKey: apiKey,
                confirmation: confirmation,
                timeout: configuration.timeout
            )
        )
    case .whisperCppInference:
        return .whisperCppInference(
            WhisperCppInferenceAdapter(
                endpointURL: configuration.endpointURL,
                confirmation: confirmation,
                timeout: configuration.timeout
            )
        )
    case .responses:
        return .responses(
            OpenAIResponsesFormatterAdapter(
                endpointURL: configuration.endpointURL,
                model: configuration.model,
                apiKey: apiKey,
                confirmation: confirmation,
                timeout: configuration.timeout
            )
        )
    case .chatCompletions:
        return .chatCompletions(
            ChatCompletionsFormatterAdapter(
                endpointURL: configuration.endpointURL,
                model: configuration.model,
                apiKey: apiKey,
                confirmation: confirmation,
                timeout: configuration.timeout
            )
        )
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
