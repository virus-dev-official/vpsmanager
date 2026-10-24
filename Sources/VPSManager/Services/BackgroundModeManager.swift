import AppKit

/// Toggling "Run in Background" needs two things to happen together: persist the
/// choice (so the next launch, handled by AppDelegate, knows what to do before any
/// window exists) and apply it live right now (so flipping it doesn't require a
/// relaunch to take effect). This keeps those two steps in one place instead of
/// duplicated across Settings and the menu bar.
enum BackgroundModeManager {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "runInBackground")
    }

    @MainActor
    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "runInBackground")
        if enabled {
            NSApp.setActivationPolicy(.accessory)
        } else {
            NSApp.showInDock()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}