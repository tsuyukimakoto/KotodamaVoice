import KotodamaCore
import SwiftUI

struct GlossarySettingsView: View {
    let runtime: AppRuntime
    @State private var editing: GlossaryEntry?
    @State private var showConsent = false
    @State private var showReset = false
    @State private var message: String?
    private var session: GlossarySession { runtime.glossarySession }
    private var settings: GlossarySettingsStore { session.settings }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "音声認識に用語集を使う",
                    isOn: Binding(get: { settings.useForSpeech }, set: settings.setSpeech)
                )
                .accessibilityIdentifier("glossary-speech")
                if runtime.speechSettings.engine == .external {
                    Text("外部Speechへの用語ヒントは未対応です。出現回数の記録は利用できます。")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier(
                            "glossary-speech-unsupported")
                }
                if session.omittedSpeechCount > 0 {
                    Text("直前の音声認識では容量の上限により\(session.omittedSpeechCount)件の用語をヒントに含めませんでした。")
                        .font(.caption).accessibilityIdentifier("glossary-omitted")
                }
                Toggle(
                    "文章整形に用語集を使う",
                    isOn: Binding(
                        get: { settings.useForFormatting },
                        set: {
                            settings.setFormatting($0)
                            if $0 && requiresConsent { showConsent = true }
                        })
                )
                .accessibilityIdentifier("glossary-formatting")
                if runtime.formatterSettings.engine == .off {
                    Text("FormatterがOffのため文脈補正は動作しません。Formattingで内蔵または外部を選択してください。")
                        .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier(
                            "glossary-formatter-inactive")
                }
                if runtime.formatterSettings.engine == .external,
                    let configuration = runtime.externalEngineSettings.configuration(
                        for: .formatter)
                {
                    Text(
                        "用語集を使うと、正しい表記・読み・説明も本文・Promptとともに \(configuration.endpointURL.absoluteString) へ送信します。"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if settings.useForFormatting && requiresConsent {
                        Text("用語集の送信は未承認のため保留中です。整形は用語集なしで行います。")
                            .font(.caption).accessibilityIdentifier("glossary-consent-missing")
                        Button("用語集の送信を許可…") { showConsent = true }
                            .accessibilityIdentifier("glossary-consent")
                    }
                }
            }
            Section("登録用語（\(settings.document.entries.count)/200）") {
                if settings.document.entries.isEmpty {
                    Text("正しい表記を登録してください。読みと説明は必要な用語にだけ追加できます。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(settings.document.entries) { entry in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(entry.term)
                                        if !entry.reading.isEmpty {
                                            Text(entry.reading).font(.caption).foregroundStyle(
                                                .secondary)
                                        }
                                    }
                                    Spacer()
                                    Button("編集") { editing = entry }.accessibilityIdentifier(
                                        "glossary-edit")
                                    Button("削除", role: .destructive) {
                                        do {
                                            try settings.delete(entry.id)
                                            message = nil
                                        } catch {
                                            message = GlossarySettingsStore.message(for: error)
                                        }
                                    }.accessibilityIdentifier("glossary-delete")
                                }
                            }
                        }
                    }.frame(maxHeight: 100)
                }
                Button("用語を追加…") { editing = GlossaryEntry(term: "") }
                    .disabled(!settings.isReadable).accessibilityIdentifier("glossary-add")
                if let error = message ?? settings.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier(
                        "glossary-error")
                }
                if !settings.isReadable {
                    HStack {
                        Button("再読み込み") { settings.reload() }
                        Button("用語集を初期化…", role: .destructive) { showReset = true }
                    }
                }
            }
            Section("診断") {
                Toggle(
                    "用語の出現回数をファイルに記録",
                    isOn: Binding(get: { settings.diagnosticsEnabled }, set: session.setDiagnostics)
                )
                .accessibilityIdentifier("glossary-diagnostics")
                Text(
                    "登録表記と、音声認識・整形後それぞれの出現回数を保存します。本文・読み・説明は保存しません。用語集の利用をオフにした比較もできます。出現回数は補正回数や正解数ではありません。"
                )
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("glossary-diagnostics-explanation")
                Button("ログフォルダを開く", action: session.diagnostics.openDirectory)
                    .accessibilityIdentifier("glossary-open-logs")
                if let error = session.diagnostics.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier(
                        "glossary-log-error")
                }
            }
        }
        .toggleStyle(.switch)
        .formStyle(.grouped)
        .sheet(item: $editing) { entry in GlossaryEntryEditor(entry: entry, settings: settings) }
        .alert("用語集を送信しますか？", isPresented: $showConsent) {
            Button("キャンセル", role: .cancel) {}
            Button("許可") {
                if let endpoint = runtime.externalEngineSettings.configuration(for: .formatter)?
                    .endpointURL
                {
                    settings.approve(endpoint)
                }
            }
        } message: {
            Text(
                "正しい表記・読み・説明を、本文・Promptとともに \(runtime.externalEngineSettings.configuration(for: .formatter)?.endpointURL.absoluteString ?? "") へ送信します。"
            )
        }
        .alert("保存された用語集を初期化しますか？", isPresented: $showReset) {
            Button("キャンセル", role: .cancel) {}
            Button("初期化", role: .destructive) {
                do { try settings.reset() } catch {
                    message = GlossarySettingsStore.message(for: error)
                }
            }
        }
    }

    private var requiresConsent: Bool {
        guard runtime.formatterSettings.engine == .external,
            let endpoint = runtime.externalEngineSettings.configuration(for: .formatter)?
                .endpointURL
        else { return false }
        return !settings.permits(endpoint)
    }
}

private struct GlossaryEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var entry: GlossaryEntry
    let settings: GlossarySettingsStore
    @State private var errorMessage: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("用語を編集").font(.headline)
            Form {
                TextField("正しい表記", text: $entry.term).accessibilityIdentifier("glossary-term")
                TextField("読み（任意）", text: $entry.reading).accessibilityIdentifier(
                    "glossary-reading")
                TextField("説明（任意）", text: $entry.note).accessibilityIdentifier("glossary-note")
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("キャンセル", role: .cancel) { dismiss() }
                Button("保存") {
                    do {
                        try settings.save(entry)
                        dismiss()
                    } catch { errorMessage = GlossarySettingsStore.message(for: error) }
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("glossary-save")
            }
        }.padding(24).frame(width: 440)
    }
}
