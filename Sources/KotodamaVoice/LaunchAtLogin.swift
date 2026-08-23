import Observation
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case disabled
    case enabled
    case requiresApproval
    case unavailable
}

@MainActor
protocol LaunchAtLoginRegistering: AnyObject {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@Observable
@MainActor
final class LaunchAtLoginSettings {
    private(set) var status: LaunchAtLoginStatus
    private(set) var errorMessage: String?

    private let backend: LaunchAtLoginRegistering

    var isEnabled: Bool {
        status == .enabled || status == .requiresApproval
    }

    init(backend: LaunchAtLoginRegistering) {
        self.backend = backend
        status = backend.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try backend.register()
            } else {
                try backend.unregister()
            }
            errorMessage = nil
        } catch {
            errorMessage = enabled
                ? "ログイン時の起動を登録できませんでした"
                : "ログイン時の起動を解除できませんでした"
        }
        status = backend.status
    }

    func refresh() {
        status = backend.status
    }
}

@MainActor
final class MainAppLaunchAtLoginBackend: LaunchAtLoginRegistering {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        switch service.status {
        case .notRegistered:
            .disabled
        case .enabled:
            .enabled
        case .requiresApproval:
            .requiresApproval
        case .notFound:
            .unavailable
        @unknown default:
            .unavailable
        }
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}
