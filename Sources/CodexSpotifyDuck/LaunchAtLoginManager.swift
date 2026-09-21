import Foundation
import ServiceManagement

protocol LoginService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginService {}

enum LaunchAtLoginManager {
    static var statusDescription: String {
        describe(SMAppService.mainApp.status)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    static func setEnabled(
        _ enabled: Bool,
        service: LoginService = SMAppService.mainApp,
        openSettings: () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) throws {
        if enabled {
            switch service.status {
            case .enabled:
                return
            case .notRegistered, .notFound:
                // A missing registration is not proof that the app is misplaced.
                // Let register() resolve the bundle and report the actual OS error.
                try service.register()
                switch service.status {
                case .enabled:
                    return
                case .requiresApproval:
                    openSettings()
                default:
                    throw LaunchAtLoginError.registrationIncomplete(describe(service.status))
                }
            case .requiresApproval:
                openSettings()
            @unknown default:
                throw LaunchAtLoginError.unknown
            }
        } else {
            switch service.status {
            case .notRegistered, .notFound:
                return
            case .enabled, .requiresApproval:
                try service.unregister()
            @unknown default:
                throw LaunchAtLoginError.unknown
            }
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .notRegistered: return "not registered"
        case .requiresApproval: return "approval required"
        case .notFound: return "not found"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }
}

enum LaunchAtLoginError: LocalizedError {
    case registrationIncomplete(String)
    case unknown

    var errorDescription: String? {
        switch self {
        case .registrationIncomplete(let status):
            return "macOS did not finish registering Launch at Login (status: \(status)). App location: \(Bundle.main.bundlePath)."
        case .unknown:
            return "Launch at Login returned an unknown status."
        }
    }
}
