import ServiceManagement

enum LaunchAtLoginManager {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration can fail if System Settings > Login Items blocks it, or
            // the app isn't in a stable location yet. Not fatal — the toggle will
            // just reflect the OS's actual status next time it's checked.
            print("LaunchAtLoginManager: \(error.localizedDescription)")
        }
    }
}