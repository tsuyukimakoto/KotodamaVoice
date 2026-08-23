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
                        install: { runtime.modelManager.install(model) },
                        select: { try? runtime.modelManager.select(model) }
                    )
                        .accessibilityIdentifier("model-\(model.id)")
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
    let install: () -> Void
    let select: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.displayName)
                    .font(.headline)
                Spacer()
                Text(statusText)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("用途", value: purposeName)
            LabeledContent(
                "容量",
                value: ByteCountFormatter.string(
                    fromByteCount: model.byteCount,
                    countStyle: .file
                )
            )
            LabeledContent("取得元", value: model.sourceURL.host() ?? "-")
            LabeledContent("ライセンス", value: model.licenseName)
            if case let .downloading(progress) = state {
                ProgressView(value: progress)
            } else if canInstall {
                Button("取得", action: install)
                    .accessibilityIdentifier("install-\(model.id)")
            } else if state == .installed {
                Button(isSelected ? "使用中" : "このモデルを使用", action: select)
                    .disabled(isSelected)
                    .accessibilityIdentifier("select-\(model.id)")
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
