import SwiftUI
import AppKit

/// Content of the menu bar dropdown. Deliberately plain — with .menuBarExtraStyle(.menu)
/// in App.swift, SwiftUI renders this as a genuine native NSMenu, so it already looks
/// like every other menu bar app on macOS: no custom colors, no gradients, no panels.
struct MenuBarContentView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Button("Open VPS Manager") {
            openMainWindow()
        }

        Button("New Window") {
            newWindow()
        }

        if !store.servers.isEmpty {
            Divider()
            ForEach(store.serverGroups) { group in
                if group.servers.count == 1, let server = group.servers.first {
                    Button(server.nickname) {
                        select(server)
                    }
                } else {
                    Menu(group.title) {
                        ForEach(group.servers) { server in
                            Button(server.nickname) {
                                select(server)
                            }
                        }
                    }
                }
            }
        }

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { LaunchAtLoginManager.isEnabled },
            set: { LaunchAtLoginManager.setEnabled($0) }
        ))

        Toggle("Run in Background", isOn: Binding(
            get: { BackgroundModeManager.isEnabled },
            set: { BackgroundModeManager.setEnabled($0) }
        ))

        Divider()

        Button("Quit VPS Manager") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openMainWindow() {
        NSApp.showInDock()
        // Reuses an existing window (even a hidden one — see AppDelegate) instead of
        // spawning a new one every time the tray icon is clicked; the app now
        // supports multiple windows, but that's an explicit "New Window" action, not
        // an implicit side effect of "open VPS Manager" from the menu bar.
        WindowOpener.shared.showMain()
        NSApp.activate(ignoringOtherApps: true)
    }

    private func select(_ server: Server) {
        store.pendingServerID = server.id
        openMainWindow()
    }

    private func newWindow() {
        NSApp.showInDock()
        // Deliberately openMain (always a fresh window), not showMain() — this is
        // the tray's equivalent of the Dock's "New Window" item and File ▸ New
        // Window, so it should behave the same way, not reuse an existing window.
        if let openMain = WindowOpener.shared.openMain {
            openMain()
        } else {
            WindowOpener.shared.showMain()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}