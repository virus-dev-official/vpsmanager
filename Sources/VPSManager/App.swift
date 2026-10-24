import SwiftUI
import AppKit

/// Started by `Entry.main()` unless the binary was launched with `--mcp`.
struct VPSManagerApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        // A WindowGroup (not a singleton Window) so the app supports multiple
        // windows open at once — each gets its own ContentView/navigation state,
        // useful for keeping two servers (or two tabs of the same server) visible
        // side by side. "Reopen" affordances that just want to surface *a* window
        // (menu bar click, Dock icon, background alerts) go through
        // WindowOpener.showMain(), which reuses an existing window instead of
        // spawning a new one every time; only an explicit "New Window" request
        // opens an additional one.
        WindowGroup("VPS Manager", id: "main") {
            ContentView()
                .environmentObject(store)
                // idealWidth/idealHeight is what a freshly opened window actually
                // sizes to; minWidth/minHeight just stops it being resized smaller
                // than the UI can handle. Both trimmed down from the previous
                // 980×640 default so new windows open at a more modest size.
                .frame(minWidth: 940, idealWidth: 1240, minHeight: 600, idealHeight: 800)
                .tint(Theme.accent)
        }
        // The system title bar is hidden; ContentView draws its own full-width
        // header (AppHeaderBar) with the traffic lights centred inside it.
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    openWindow(id: "main")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("New Server…") {
                    NotificationCenter.default.post(name: .newServerRequested, object: nil)
                }
                .keyboardShortcut("n", modifiers: [.command])

                Button("Import Servers from SSH Config…") {
                    NotificationCenter.default.post(name: .importSSHConfigRequested, object: nil)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .newItem) {
                Button("Quick Switcher…") {
                    NotificationCenter.default.post(name: .quickSwitcherRequested, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command])
            }
        }

        // .menu style renders this as a real native NSMenu dropdown — plain system
        // appearance, matching the rest of the app, not a custom-styled panel.
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(store)
        } label: {
            Image(nsImage: MenuBarIcon.image)
                .accessibilityLabel("VPS Manager")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

extension Notification.Name {
    static let newServerRequested = Notification.Name("newServerRequested")
    static let quickSwitcherRequested = Notification.Name("quickSwitcherRequested")
    static let importSSHConfigRequested = Notification.Name("importSSHConfigRequested")
}