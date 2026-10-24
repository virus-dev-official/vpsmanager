import AppKit
import SwiftUI

/// Running straight from Xcode (or `swift run`) launches the bare executable,
/// which has no bundle and so no AppIcon.icns — the Dock shows a generic
/// "exec" tile. SwiftPM doesn't put the AppIcon set into Assets.car either, so
/// the brand mark is drawn on the 1024pt macOS icon grid (824pt tile, 100pt
/// margin) and used instead. A packaged .app keeps its real icon.
///
/// The Dock tile is recreated every time the app switches from `.accessory` back
/// to `.regular`, and the new tile starts out with the exec icon again, so the
/// icon has to be reapplied after each switch rather than once at launch.
@MainActor
enum DockIcon {
    private static let isUnbundled = Bundle.main.bundleURL.pathExtension != "app"

    private static let developmentImage: NSImage? = {
        let renderer = ImageRenderer(content: BrandMark(size: 824).padding(100))
        renderer.scale = 1
        return renderer.nsImage
    }()

    static func apply() {
        guard isUnbundled, let image = developmentImage else { return }
        NSApp.applicationIconImage = image
    }
}

extension NSApplication {
    /// Makes the app a regular Dock app again (after Run in Background put it in
    /// `.accessory`) and restores the development Dock icon if needed.
    @MainActor
    func showInDock() {
        setActivationPolicy(.regular)
        DockIcon.apply()
    }
}
