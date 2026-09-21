import Foundation
import ServiceManagement

private final class FakeLoginService: LoginService {
    var status: SMAppService.Status
    var registeredStatus: SMAppService.Status = .enabled
    var registrationError: Error?
    var registrations = 0
    var unregistrations = 0

    init(_ status: SMAppService.Status) { self.status = status }

    func register() throws {
        registrations += 1
        if let registrationError { throw registrationError }
        status = registeredStatus
    }

    func unregister() throws {
        unregistrations += 1
        status = .notRegistered
    }
}

@main
private enum LaunchAtLoginTests {
    static func main() throws {
        for initial: SMAppService.Status in [.notRegistered, .notFound] {
            let service = FakeLoginService(initial)
            try LaunchAtLoginManager.setEnabled(true, service: service, openSettings: {})
            precondition(service.registrations == 1 && service.status == .enabled)
        }

        let enabled = FakeLoginService(.enabled)
        try LaunchAtLoginManager.setEnabled(true, service: enabled, openSettings: {})
        precondition(enabled.registrations == 0)

        for initial: SMAppService.Status in [.notRegistered, .requiresApproval] {
            let service = FakeLoginService(initial)
            service.registeredStatus = .requiresApproval
            var settingsOpened = false
            try LaunchAtLoginManager.setEnabled(true, service: service) { settingsOpened = true }
            precondition(settingsOpened && service.status == .requiresApproval)
            precondition(service.registrations == (initial == .requiresApproval ? 0 : 1))
        }

        let incomplete = FakeLoginService(.notFound)
        incomplete.registeredStatus = .notFound
        do {
            try LaunchAtLoginManager.setEnabled(true, service: incomplete, openSettings: {})
            fatalError("Incomplete registration must not be reported as successful")
        } catch LaunchAtLoginError.registrationIncomplete {}

        let rejected = FakeLoginService(.notFound)
        rejected.registrationError = NSError(domain: "TestRegistration", code: 42)
        do {
            try LaunchAtLoginManager.setEnabled(true, service: rejected, openSettings: {})
            fatalError("Registration errors must be preserved")
        } catch {
            precondition((error as NSError).domain == "TestRegistration")
            precondition((error as NSError).code == 42)
        }

        for initial: SMAppService.Status in [.enabled, .requiresApproval, .notRegistered, .notFound] {
            let service = FakeLoginService(initial)
            try LaunchAtLoginManager.setEnabled(false, service: service, openSettings: {})
            precondition(service.unregistrations == ((initial == .enabled || initial == .requiresApproval) ? 1 : 0))
        }

        print("PASS: 11 Launch at Login registration checks")
    }
}
