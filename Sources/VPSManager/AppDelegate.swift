import AppKit
import SwiftUI

/// Handles the things SwiftUI's App lifecycle doesn't give clean control over:
/// whether the app should pop its main window open at launch (vs. start quietly in
/// the menu bar), stopping macOS from silently reopening extra windows on its own,
/// and supplying a Dock right-click menu. Everything else (the menu bar item itself,
/// its content, reopening the window) is handled declaratively via
/// MenuBarExtra/WindowGroup in App.swift.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set the Dock icon as early as possible so an Xcode/`swift run` launch
    /// doesn't flash the generic exec tile first (see DockIcon).
    func applicationWillFinishLaunching(_ notification: Notification) {
        DockIcon.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearanceMode.current.apply()
        if UserDefaults.standard.bool(forKey: "runInBackground") {
            NSApp.setActivationPolicy(.accessory)
            // SwiftUI's Window scene still creates its window automatically at
            // launch even under .accessory — hide it immediately so the app
            // genuinely starts silent in the menu bar rather than flashing a
            // window open and shut.
            //
            // Deliberately `orderOut(nil)`, NOT `.close()`. Calling `.close()` on a
            // window owned by a SwiftUI `Window` scene tears down SwiftUI's own
            // bookkeeping for that window id — after that, `openWindow(id: "main")`
            // from the menu bar silently does nothing, because as far as SwiftUI is
            // concerned that window still "exists" (it doesn't check AppKit, it
            // checks its own state). `orderOut` just hides it, so the scene's state
            // stays intact and the menu bar's "Open VPS Manager" can bring it back.
            DispatchQueue.main.async {
                NSApp.windows.forEach { $0.orderOut(nil) }
            }
        } else {
            NSApp.showInDock()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Opts every window in the app out of AppKit's automatic window state
    /// restoration. Without this, macOS remembers how many windows were open when
    /// the app last quit (via each NSWindow's restorable state) and silently
    /// recreates all of them the next time the app launches — *in addition to* the
    /// one window the "main" WindowGroup already opens on its own at startup. That's
    /// exactly what produced two windows immediately on open: once the "New Window"
    /// command had been used even a single time in a previous session, the next
    /// launch restored that second window on top of the fresh one WindowGroup
    /// always creates. Returning false here tells AppKit this app doesn't
    /// participate in restoration at all, so launch always starts from exactly the
    /// one window WindowGroup creates. (See also `WindowAccessor` in
    /// ContentView.swift, which additionally marks each window `isRestorable =
    /// false` directly, as a second, redundant guard against the same problem.)
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    /// Closes every local SSH tunnel (remote browser sessions, port forwards) so no
    /// orphaned `ssh -N` processes outlive the app.
    func applicationWillTerminate(_ notification: Notification) {
        RemoteBrowserManager.shared.shutdownAll()
        PortForwardService.shared.stopAll()
    }

    /// Fires when the app is opened again while already running — a Dock click,
    /// or double-clicking it in Finder/Launchpad/Spotlight while it sits in the
    /// menu bar.
    ///
    /// The return value matters: `true` tells SwiftUI to run its own default
    /// reopen handling, which for a WindowGroup means "create a new window when
    /// none is visible". A window hidden by Run in Background (`orderOut`) is
    /// not visible, so returning `true` here used to surface that hidden window
    /// *and* have SwiftUI spawn a second one next to it. Only fall back to
    /// SwiftUI's default when there was genuinely nothing to show.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.showInDock()
        let handled = WindowOpener.shared.showMain()
        NSApp.activate(ignoringOtherApps: true)
        return !handled
    }

    /// Supplies the extra items macOS merges into the Dock icon's right-click (or
    /// press-and-hold) menu, above the standard Options/Show All Windows/Hide/Quit
    /// block. Without implementing this, that menu has no way at all to spawn a new
    /// window — unlike the menu bar extra's "Open VPS Manager", a Dock menu doesn't
    /// exist unless the app builds one explicitly.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let newWindowItem = NSMenuItem(
            title: "New Window",
            action: #selector(newWindowFromDockMenu),
            keyEquivalent: ""
        )
        newWindowItem.target = self
        menu.addItem(newWindowItem)

        return menu
    }

    @objc private func newWindowFromDockMenu() {
        NSApp.showInDock()
        NSApp.activate(ignoringOtherApps: true)
        if let openMain = WindowOpener.shared.openMain {
            // Always opens a brand-new window — this is an explicit "New Window"
            // request, so it deliberately does not go through showMain()'s
            // reuse-an-existing-window behavior.
            openMain()
        } else {
            // openMain is only assigned once ContentView's .task has run for some
            // window (see ContentView.swift); if the app is mid-launch and that
            // hasn't happened yet, fall back to just surfacing the window that's
            // already on its way up rather than doing nothing.
            WindowOpener.shared.showMain()
        }
    }
}