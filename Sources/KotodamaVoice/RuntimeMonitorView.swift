import KotodamaCore
import SwiftUI

struct RuntimeMonitorView: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        List {
            workerSection(name: "Speech Worker", endpoint: .speech)
            workerSection(name: "Formatter Worker", endpoint: .formatter)
        }
        .navigationTitle("Runtime Monitor")
        .toolbar {
            Button("更新") {
                runtime.workerDiagnostics.refresh()
            }
            .accessibilityIdentifier("worker-diagnostics-button")
        }
        .onAppear {
            runtime.workerDiagnostics.startMonitoring()
        }
        .onDisappear {
            runtime.workerDiagnostics.stopMonitoring()
        }
    }

    @ViewBuilder
    private func workerSection(
        name: String,
        endpoint: WorkerEndpoint
    ) -> some View {
        Section(name) {
            switch runtime.workerDiagnostics.states[endpoint] {
            case .disconnected, nil:
                statusRow("未接続")
            case .checking:
                statusRow("確認中")
            case let .connected(snapshot):
                connectedRows(snapshot)
            case .failed:
                statusRow("接続失敗")
            }
        }
    }

    private func statusRow(_ status: String) -> some View {
        LabeledContent("接続", value: status)
    }

    @ViewBuilder
    private func connectedRows(_ snapshot: WorkerMonitorSnapshot) -> some View {
        LabeledContent("接続", value: "接続済み")
        LabeledContent("状態", value: lifecycleLabel(snapshot.worker.state))
        LabeledContent(
            "PID",
            value: String(snapshot.worker.processIdentifier)
        )
        if let modelID = snapshot.worker.modelID {
            LabeledContent("モデル", value: modelID)
        }
        if let usesMetal = snapshot.worker.usesMetal {
            LabeledContent("Metal", value: usesMetal ? "使用" : "未使用")
        }
        if let footprint = snapshot.resources?.physicalFootprintBytes {
            LabeledContent(
                "Physical footprint",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(footprint),
                    countStyle: .memory
                )
            )
        }
        if let cpu = snapshot.resources?.cpuPercentage {
            LabeledContent(
                "CPU",
                value: cpu.formatted(.number.precision(.fractionLength(1))) + "%"
            )
        }
        if let request = snapshot.worker.lastRequest {
            LabeledContent(
                "直近のrequest ID",
                value: request.requestID.rawValue.uuidString
            )
            LabeledContent(
                "直近の結果",
                value: request.result == .succeeded ? "成功" : "失敗"
            )
            LabeledContent(
                "処理時間",
                value: request.processingMilliseconds.formatted(
                    .number.precision(.fractionLength(1))
                ) + " ms"
            )
            if let promptRate = request.promptTokensPerSecond {
                LabeledContent(
                    "Prompt速度",
                    value: tokenRate(promptRate)
                )
            }
            if let generationRate = request.generationTokensPerSecond {
                LabeledContent(
                    "生成速度",
                    value: tokenRate(generationRate)
                )
            }
        }
    }

    private func lifecycleLabel(_ state: WorkerLifecycleState) -> String {
        switch state {
        case .idle:
            "待機"
        case .loaded:
            "ロード済み"
        case .shutDown:
            "終了済み"
        }
    }

    private func tokenRate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " tokens/s"
    }
}
