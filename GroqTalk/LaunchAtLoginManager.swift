import ServiceManagement

@MainActor
@Observable
final class LaunchAtLoginManager {
    private(set) var isEnabled: Bool

    init() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshStatus()  // read back actual state instead of assuming success
        } catch {
            DiagnosticLog.write("Launch at login toggle failed: \(error.localizedDescription)")
            refreshStatus()  // also refresh on error to show true state
        }
    }

    func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
