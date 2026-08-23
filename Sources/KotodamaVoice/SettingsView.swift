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

            PlaceholderSettingsView(
                title: "Formatting",
                detail: "文章整形の利用方法を設定します。"
            )
            .tabItem {
                Label("Formatting", systemImage: "text.alignleft")
                    .accessibilityIdentifier("formatting-settings")
            }

            PlaceholderSettingsView(
                title: "Output",
                detail: "ClipboardまたはAuto Insertを選択します。"
            )
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
