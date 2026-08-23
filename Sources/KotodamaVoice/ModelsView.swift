import KotodamaCore
import SwiftUI

struct ModelsView: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        Group {
            if let loadError = runtime.modelCatalog.loadError {
                ContentUnavailableView(
                    "モデル情報を読み込めません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                List(runtime.modelCatalog.models) { model in
                    ModelRow(
                        model: model,
                        state: runtime.modelManager.states[model.id]
                            ?? .notInstalled,
                        isSelected: runtime.modelManager
                            .selectedModel(for: model.purpose)?.id == model.id,
                        deletionError: runtime.modelManager.deletionErrors[model.id],
                        install: { runtime.modelManager.install(model) },
                        select: { try? runtime.modelManager.select(model) },
                        delete: { runtime.modelManager.requestDeletion(model) }
                    )
                }
            }
        }
        .navigationTitle("モデル")
    }
}

private struct ModelRow: View {
    let model: ModelManifestEntry
    let state: ModelAvailability
    let isSelected: Bool
    let deletionError: String?
    let install: () -> Void
    let select: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.displayName)
                    .font(.headline)
                    .accessibilityIdentifier("model-\(model.id)-name")
                Spacer()
                Text(statusText)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("model-\(model.id)-status")
            }
            LabeledContent("用途") {
                Text(purposeName)
                    .accessibilityIdentifier("model-\(model.id)-purpose")
            }
            LabeledContent("容量") {
                Text(ByteCountFormatter.string(
                    fromByteCount: model.byteCount,
                    countStyle: .file
                ))
                    .accessibilityIdentifier("model-\(model.id)-size")
            }
            LabeledContent("取得元") {
                Text(model.sourceURL.host() ?? "-")
                    .accessibilityIdentifier("model-\(model.id)-source")
            }
            LabeledContent("ライセンス") {
                Text(model.licenseName)
                    .accessibilityIdentifier("model-\(model.id)-license")
            }
            if case let .downloading(progress) = state {
                ProgressView(value: progress)
            } else if canInstall {
                Button("取得", action: install)
                    .accessibilityIdentifier("install-\(model.id)")
            } else if state == .installed {
                HStack {
                    Button(isSelected ? "使用中" : "このモデルを使用", action: select)
                        .disabled(isSelected)
                        .accessibilityIdentifier("select-\(model.id)")
                    Button("削除", role: .destructive) {
                        delete()
                    }
                    .accessibilityIdentifier("delete-\(model.id)")
                }
            }
            if let deletionError {
                Text(deletionError)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("delete-error-\(model.id)")
            }
        }
        .padding(.vertical, 8)
    }

    private var purposeName: String {
        switch model.purpose {
        case .speech:
            "文字起こし"
        case .formatter:
            "文章整形"
        }
    }

    private var canInstall: Bool {
        switch state {
        case .notInstalled, .failed:
            true
        case .downloading, .installed, .storageUnavailable:
            false
        }
    }

    private var statusText: String {
        switch state {
        case .notInstalled:
            "未導入"
        case let .downloading(progress):
            "取得中 \(Int(progress * 100))%"
        case .installed:
            "導入済み"
        case let .failed(message):
            message
        case .storageUnavailable:
            "App Groupを利用できません"
        }
    }
}
