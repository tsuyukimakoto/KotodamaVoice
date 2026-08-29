import KotodamaCore
import SwiftUI

struct ModelsView: View {
    @Environment(AppRuntime.self) private var runtime
    private let licenseCatalog = try? LicenseCatalog()

    var body: some View {
        Group {
            if let loadError = runtime.modelCatalog.loadError {
                ContentUnavailableView(
                    "モデル情報を読み込めません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(loadError)
                )
            } else {
                ScrollViewReader { proxy in
                    List(runtime.modelCatalog.models) { model in
                        ModelRow(
                            model: model,
                            state: runtime.modelManager.states[model.id]
                                ?? .notInstalled,
                            isSelected: runtime.modelManager
                                .selectedModel(for: model.purpose)?.id == model.id,
                            deletionError: runtime.modelManager.deletionErrors[model.id],
                            licenseDocument: licenseCatalog?.documents.first {
                                $0.licenseFile == model.licenseFile
                            },
                            install: { runtime.modelManager.install(model) },
                            select: { try? runtime.modelManager.select(model) },
                            delete: { runtime.requestModelDeletion(model) }
                        )
                        .id(model.id)
                        .listRowBackground(
                            model.id == runtime.modelNavigationTargetID
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                    .onAppear {
                        scrollToNavigationTarget(using: proxy)
                    }
                    .onChange(of: runtime.modelNavigationTargetID) {
                        scrollToNavigationTarget(using: proxy)
                    }
                }
            }
        }
        .navigationTitle("モデル")
    }

    private func scrollToNavigationTarget(using proxy: ScrollViewProxy) {
        guard let modelID = runtime.modelNavigationTargetID else { return }
        Task { @MainActor in
            proxy.scrollTo(modelID, anchor: .center)
        }
    }
}

private struct ModelRow: View {
    let model: ModelManifestEntry
    let state: ModelAvailability
    let isSelected: Bool
    let deletionError: String?
    let licenseDocument: LicenseDocument?
    let install: () -> Void
    let select: () -> Void
    let delete: () -> Void
    @State private var showsBundledLicense = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(model.displayName)
                    .font(.headline)
                    .accessibilityIdentifier("model-\(model.id)-name")
                if model.isDefault {
                    Text("標準")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .accessibilityIdentifier("model-\(model.id)-default")
                }
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
                HStack {
                    Text(model.sourceURL.host() ?? "-")
                        .accessibilityIdentifier("model-\(model.id)-source")
                    Link("開く", destination: model.sourceURL)
                        .accessibilityIdentifier(
                            "model-\(model.id)-source-link"
                        )
                }
            }
            LabeledContent("Revision") {
                Text(model.revision)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("model-\(model.id)-revision")
            }
            LabeledContent("ライセンス") {
                HStack {
                    Text(model.licenseName)
                        .accessibilityIdentifier("model-\(model.id)-license")
                    if licenseDocument != nil {
                        Button("同梱文書を表示") {
                            showsBundledLicense = true
                        }
                        .accessibilityIdentifier(
                            "model-\(model.id)-bundled-license"
                        )
                    }
                    Link("公式ページ", destination: model.licenseURL)
                        .accessibilityIdentifier(
                            "model-\(model.id)-official-license"
                        )
                }
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
        .sheet(isPresented: $showsBundledLicense) {
            if let licenseDocument {
                NavigationStack {
                    ScrollView {
                        Text(licenseDocument.text)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle(licenseDocument.displayName)
                    .frame(minWidth: 620, minHeight: 480)
                }
            }
        }
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
