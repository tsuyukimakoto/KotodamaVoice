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
                externalSettings: runtime.externalEngineSettings,
                engineSelection: runtime.formatterEngineSelection,
                beginModelAcquisition: {
                    runtime.beginPendingFormatterModelAcquisition()
                    openWindow(id: "models")
                }
            )
            .tabItem {
                Label("Formatting", systemImage: "text.alignleft")
                    .accessibilityIdentifier("formatting-settings")
            }

            GlossarySettingsView(runtime: runtime)
                .tabItem {
                    Label("用語集", systemImage: "text.book.closed").accessibilityIdentifier(
                        "glossary-settings")
                }

            OutputSettingsView(settings: runtime.outputSettings)
                .tabItem {
                    Label("Output", systemImage: "clipboard")
                        .accessibilityIdentifier("output-settings")
                }

            LicenseSettingsView()
                .tabItem {
                    Label("Licenses", systemImage: "doc.text")
                        .accessibilityIdentifier("license-settings")
                }

        }
        .padding(20)
        .frame(width: 680, height: 560)
    }
}

private struct LicenseSettingsView: View {
    private let result: Result<LicenseCatalog, Error>

    init(bundle: Bundle = .main) {
        result = Result { try LicenseCatalog(bundle: bundle) }
    }

    var body: some View {
        switch result {
        case .success(let catalog):
            List(catalog.documents) { document in
                DisclosureGroup {
                    ScrollView {
                        Text(document.text)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    .frame(minHeight: 180, maxHeight: 280)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(document.displayName)
                            .accessibilityIdentifier(
                                "license-\(document.id)-name"
                            )
                        Text(document.licenseName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("license-document-list")
        case .failure:
            ContentUnavailableView(
                "ライセンス文書を読み込めません",
                systemImage: "exclamationmark.triangle",
                description: Text("同梱文書を確認してください。")
            )
        }
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
    @Environment(\.scenePhase) private var scenePhase
    let settings: OutputSettingsStore
    @State private var showsAccessibilityExplanation = false

    var body: some View {
        Form {
            Section("出力方式") {
                Picker(
                    "出力方式",
                    selection: Binding(
                        get: { settings.selectedMode },
                        set: { mode in select(mode) }
                    )
                ) {
                    ForEach(OutputMode.allCases) { mode in
                        Text(mode.displayName).tag(Optional(mode))
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("output-mode-picker")

                LabeledContent("現在の出力") {
                    Text(currentOutputDescription)
                        .accessibilityIdentifier("output-mode-value")
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.permissionResult == .permissionRequired {
                Section("Accessibility権限") {
                    Label("Auto Insertの許可待ちです", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("システム設定でKotodamaVoiceのAccessibilityを許可してください。許可が確認できるまで出力方式は未設定のままです。")
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                settings.applicationDidBecomeActive()
            }
        }
    }

    private var currentOutputDescription: String {
        if settings.isAwaitingAccessibilityPermission {
            return "未設定（Auto Insertの許可待ち）"
        }
        return settings.mode?.displayName ?? "未設定"
    }

    private var detail: String {
        if settings.isAwaitingAccessibilityPermission {
            return "許可を確認できた時点でAuto Insertが設定されます。それまでは録音を開始できません。"
        }
        switch settings.mode {
        case nil:
            return "録音結果の出力先を選択してください。Clipboardは追加の権限を使用しません。"
        case .clipboard:
            return "結果をClipboardへコピーします。Accessibility権限は使用しません。"
        case .autoInsert:
            return "録音開始時に選択されていた入力欄を再確認して結果を挿入します。"
        }
    }

    private func select(_ mode: OutputMode?) {
        guard let mode else { return }
        switch mode {
        case .clipboard:
            settings.selectClipboard()
        case .autoInsert:
            showsAccessibilityExplanation = true
        }
    }
}

@MainActor
final class OutputSelectionWindowPresenter {
    private let settings: OutputSettingsStore
    private var window: NSWindow?

    init(settings: OutputSettingsStore) {
        self.settings = settings
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let rootView = OutputSelectionView(
            settings: settings,
            complete: { [weak self] in self?.window?.close() }
        )
        let controller = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: controller)
        window.title = "出力方式を選択"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 500, height: 360))
        window.setFrameAutosaveName("OutputSelectionWindow")
        window.identifier = NSUserInterfaceItemIdentifier("output-selection-window")
        return window
    }
}

private struct OutputSelectionView: View {
    @Environment(\.scenePhase) private var scenePhase
    let settings: OutputSettingsStore
    let complete: () -> Void
    @State private var showsAccessibilityExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("録音結果の出力先を選択してください")
                    .font(.title2.bold())
                Text("選択するまでは録音を開始しません。後から設定で変更できます。")
                    .foregroundStyle(.secondary)
            }

            choice(
                title: "Clipboard",
                description: "結果をクリップボードへコピーします。追加の権限は不要です。",
                systemImage: "clipboard",
                recommended: true
            ) {
                settings.selectClipboard()
                complete()
            }
            .accessibilityIdentifier("choose-clipboard-output")

            choice(
                title: "Auto Insert",
                description: "録音開始時に選択されていた入力欄へ挿入します。Accessibility権限が必要です。",
                systemImage: "text.cursor",
                recommended: false
            ) {
                showsAccessibilityExplanation = true
            }
            .accessibilityIdentifier("choose-auto-insert-output")

            if settings.isAwaitingAccessibilityPermission {
                Label(
                    "Accessibilityの許可を確認できるまで未設定です",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("output-selection-permission-required")
            }

            #if DEBUG
                if ProcessInfo.processInfo.environment["KOTODAMA_UI_TESTING"] == "1" {
                    Text("\(settings.permissionPromptRequestCount)")
                        .accessibilityIdentifier("output-selection-prompt-count")
                }
            #endif
        }
        .padding(28)
        .alert(
            "Auto Insertを有効にしますか？",
            isPresented: $showsAccessibilityExplanation
        ) {
            Button("キャンセル", role: .cancel) {}
            Button("許可を要求") {
                if settings.requestAutoInsertPermission() == .enabled {
                    complete()
                }
            }
        } message: {
            Text("録音開始時に選択されていた入力欄へ結果を挿入するため、macOSのAccessibility権限が必要です。")
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                settings.applicationDidBecomeActive()
            }
        }
        .onChange(of: settings.mode) { _, mode in
            if mode != nil {
                complete()
            }
        }
    }

    private func choice(
        title: String,
        description: String,
        systemImage: String,
        recommended: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(.headline)
                        if recommended {
                            Text("おすすめ")
                                .font(.caption)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.15), in: Capsule())
                        }
                    }
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FormattingSettingsView: View {
    @Environment(\.openURL) private var openURL
    let settings: FormatterSettingsStore
    let externalSettings: ExternalEngineSettingsStore
    let engineSelection: FormatterEngineSelectionCoordinator
    let beginModelAcquisition: () -> Void
    @State private var showsOverwriteConfirmation = false
    @State private var showsModelAcquisitionConfirmation = false
    @State private var selectionError: String?

    var body: some View {
        Form {
            Section("文章整形") {
                Picker(
                    "Formatter",
                    selection: Binding(
                        get: { settings.engine },
                        set: { select($0) }
                    )
                ) {
                    ForEach(FormattingEngine.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.radioGroup)
                .accessibilityIdentifier("formatter-engine-picker")

                LabeledContent("現在のFormatter") {
                    Text(settings.engine.displayName)
                        .accessibilityIdentifier("formatter-engine-value")
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("formatter-engine-detail")

                if let selectionError {
                    Text(selectionError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("formatter-engine-error")
                }
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
                        value:
                            "\(settings.defaultPrompt.identifier) v\(settings.defaultPrompt.version)"
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
        .alert(
            "モデルを取得しますか？",
            isPresented: $showsModelAcquisitionConfirmation
        ) {
            Button("キャンセル", role: .cancel) {
                engineSelection.cancelPendingModelAcquisition()
            }
            Button("公式ライセンスを開く") {
                if let model = engineSelection.pendingModel {
                    openURL(model.licenseURL)
                }
            }
            Button("取得して内蔵を使用") {
                beginModelAcquisition()
            }
        } message: {
            Text(modelAcquisitionMessage)
        }
    }

    private func select(_ engine: FormattingEngine) {
        selectionError = nil
        switch engineSelection.select(engine) {
        case .applied:
            break
        case .requiresModel:
            showsModelAcquisitionConfirmation = true
        case .unavailable:
            selectionError = "取得できるFormatterモデルがありません。モデル情報を確認してください。"
        }
    }

    private var modelAcquisitionMessage: String {
        guard let model = engineSelection.pendingModel else {
            return "Formatterモデルの情報を確認できません。"
        }
        return """
            \(model.displayName)
            容量: \(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
            取得元: \(model.sourceURL.host() ?? "-")
            Revision: \(model.revision)
            ライセンス: \(model.licenseName)
            """
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
    @State private var confirmationRequirements: Set<ExternalEndpointConfirmationRequirement> = []
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
                statusMessage =
                    result == .ready
                    ? "接続できました"
                    : "Endpointの契約を確認できませんでした"
            } catch {
                statusMessage = "接続を確認できませんでした"
            }
            isTesting = false
        }
    }
}

extension ExternalEndpointPurpose {
    fileprivate var engineKinds: [ExternalEngineKind] {
        ExternalEngineKind.allCases.filter { $0.purpose == self }
    }

    fileprivate var defaultEngineKind: ExternalEngineKind {
        switch self {
        case .speech: .openAIAudioTranscriptions
        case .formatter: .responses
        }
    }
}

extension ExternalEngineKind {
    fileprivate var displayName: String {
        switch self {
        case .openAIAudioTranscriptions: "OpenAI Audio Transcriptions"
        case .whisperCppInference: "whisper.cpp /inference"
        case .responses: "OpenAI Responses / LM Studio"
        case .chatCompletions: "Chat Completions / llama-server"
        }
    }

    fileprivate var requiresModel: Bool {
        self != .whisperCppInference
    }
}

private func connection(
    configuration: ExternalEngineConfiguration,
    apiKey: String?
) throws -> ExternalEngineConnection {
    let confirmation =
        configuration.acceptedConfirmations.isEmpty
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

            Section("デバッグ") {
                Toggle(
                    "エラーログを記録",
                    isOn: Binding(
                        get: { runtime.debugLogSettings.isEnabled },
                        set: { runtime.debugLogSettings.setEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .accessibilityIdentifier("debug-logging-toggle")
                Text("問題の発生箇所やエラー種別を記録します。入力内容、文字起こし結果、クリップボード内容、API Keyは記録しません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if runtime.debugLogSettings.isEnabled {
                    Button("ログフォルダを開く") {
                        runtime.debugLogSettings.openLogDirectory()
                    }
                    .accessibilityIdentifier("debug-log-folder-button")
                }
                if let errorMessage = runtime.debugLogSettings.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("debug-log-error")
                }
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
