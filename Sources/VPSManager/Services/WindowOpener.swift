import Foundation
import AppKit

@MainActor
final class WindowOpener {
    static let shared = WindowOpener()

    /// Always opens a brand-new main window (assigned in ContentView's `.task` to
    /// `openWindow(id: "main")`). Use this only for an explicit, deliberate "give me
    /// a new window" request — e.g. the File ▸ New Window command.
    var openMain: (() -> Void)?

    /// Every main window ContentView has been mounted in (see `WindowAccessor` in
    /// ContentView.swift). Tracked here rather than by overwriting
    /// `NSWindow.identifier`, which SwiftUI's WindowGroup uses for its own
    /// bookkeeping — re-tagging it can make SwiftUI lose track of a window it
    /// created and open a fresh one instead.
    private let mainWindows = NSHashTable<NSWindow>.weakObjects()

    func register(_ window: NSWindow) {
        guard !mainWindows.contains(window) else { return }
        mainWindows.add(window)
        // A window the user closed is gone for good as far as SwiftUI is concerned;
        // bringing it back with makeKeyAndOrderFront would show a dead shell.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                if let window { self?.mainWindows.remove(window) }
            }
        }
    }

    /// Brings an already-open main window to the front if one exists (even if it's
    /// merely hidden via `orderOut`, e.g. from "Run in Background" — see
    /// AppDelegate); otherwise opens a new one. This is what every "reopen" affordance
    /// — the menu bar item, Dock icon reopen, a background health alert — should call,
    /// so that clicking them repeatedly re-focuses one window instead of piling up
    /// duplicates. Contrast with `openMain`, which always creates a new window.
    ///
    /// Returns whether a window was shown or opened. At startup `openMain` may still
    /// be nil while SwiftUI wires up its first window; then this is a no-op and
    /// returns false, so callers like the Dock reopen handler can let SwiftUI's
    /// default behaviour take over instead of creating a second window.
    @discardableResult
    func showMain() -> Bool {
        if let existing = existingMainWindow() {
            if existing.isMiniaturized { existing.deminiaturize(nil) }
            existing.makeKeyAndOrderFront(nil)
            return true
        }

        guard let openMain else {
            return false
        }

        openMain()
        return true
    }

    /// A registered main window, preferring one that is already on screen; failing
    /// that, any SwiftUI WindowGroup window for the "main" scene (e.g. one hidden
    /// by Run in Background before `WindowAccessor` got to register it).
    private func existingMainWindow() -> NSWindow? {
        let registered = mainWindows.allObjects
        if let window = registered.first(where: \.isVisible) ?? registered.first {
            return window
        }
        return NSApp.windows.first { window in
            !(window is NSPanel)
                && window.canBecomeMain
                && window.identifier?.rawValue.hasPrefix("main") == true
        }
    }
}
