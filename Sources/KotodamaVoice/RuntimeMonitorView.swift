import SwiftUI

struct RuntimeMonitorView: View {
    @Environment(AppRuntime.self) private var runtime

    var body: some View {
        List {
            workerRow(name: "Speech Worker", endpoint: .speech)
            workerRow(name: "Formatter Worker", endpoint: .formatter)
        }
        .navigationTitle("Runtime Monitor")
        .toolbar {
            Button("接続を確認") {
                runtime.workerDiagnostics.checkAll()
            }
            .accessibilityIdentifier("worker-diagnostics-button")
        }
    }

    private func workerRow(
        name: String,
        endpoint: WorkerEndpoint
    ) -> some View {
        LabeledContent(name) {
            Text(label(for: runtime.workerDiagnostics.states[endpoint]))
                .foregroundStyle(.secondary)
        }
    }

    private func label(for state: WorkerDiagnosticState?) -> String {
        switch state {
        case .disconnected, nil:
            "未接続"
        case .checking:
            "確認中"
        case .connected:
            "接続済み"
        case .failed:
            "接続失敗"
        }
    }
}
