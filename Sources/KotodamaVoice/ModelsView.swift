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
                    ModelRow(model: model)
                        .accessibilityIdentifier("model-\(model.id)")
                }
            }
        }
        .navigationTitle("モデル")
    }
}

private struct ModelRow: View {
    let model: ModelManifestEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.displayName)
                    .font(.headline)
                Spacer()
                Text("未導入")
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
}
