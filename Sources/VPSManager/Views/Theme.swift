import SwiftUI
import AppKit

// MARK: - Palette
//
// One place for every brand color in the app. Each token resolves dynamically
// against the current NSAppearance, so the same `Theme.surface` reads as a
// warm white card in light mode and a deep charcoal panel in dark mode — an
// "ember" look: a vermilion-to-orange brand on warm neutrals, in both themes.
// Danger leans crimson and warning leans gold so status colors never blur
// into the orange accent.

enum Theme {
    static let accent = Color.dynamic(light: 0xCF4510, dark: 0xEC6226)
    static let accentStrong = Color.dynamic(light: 0xA9370B, dark: 0xFF9A66)

    /// Window / content background.
    static let canvas = Color.dynamic(light: 0xFAF6F4, dark: 0x141110)
    /// Cards and raised panels.
    static let surface = Color.dynamic(light: 0xFFFFFF, dark: 0x1C1715)
    /// Inset areas inside a card (toolbars, inputs, secondary rows).
    static let surfaceAlt = Color.dynamic(light: 0xF8F2EF, dark: 0x241D1A)
    /// Hairline borders.
    static let stroke = Color.dynamic(light: 0xEBE1DC, dark: 0x352A25)
    /// Sidebar background.
    static let sidebar = Color.dynamic(light: 0xFDFAF8, dark: 0x0F0C0B)
    /// Sidebar row hover / selection wash.
    static let sidebarSelection = Color.dynamic(light: 0xFCE7DC, dark: 0x3A1D12)

    /// The app header bar: a vermilion-to-ember band in light mode, deep
    /// smoldering brown-red in dark — always paired with white content.
    static let headerTop = Color.dynamic(light: 0xE0521A, dark: 0x4A1D0E)
    static let headerBottom = Color.dynamic(light: 0xC2380C, dark: 0x30120A)
    static var headerGradient: LinearGradient {
        LinearGradient(colors: [headerTop, headerBottom], startPoint: .top, endPoint: .bottom)
    }
    /// The bottom status bar.
    static let statusBar = Color.dynamic(light: 0xF4EDE9, dark: 0x0F0C0B)

    static let success = Color.dynamic(light: 0x15803D, dark: 0x3DD68C)
    static let warning = Color.dynamic(light: 0xA16207, dark: 0xF4C03A)
    static let danger = Color.dynamic(light: 0xC81E3A, dark: 0xFF5C70)

    /// The two stops of the brand gradient (app icon, logo mark, hero accents).
    static let brandTop = Color(hex: 0xFF8A3D)
    static let brandBottom = Color(hex: 0xE0311B)
    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brandTop, brandBottom], startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(nsColor: NSColor(hex: hex, alpha: opacity))
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: CGFloat(alpha)
        )
    }
}

// MARK: - Appearance

/// Light / Dark / System, applied app-wide through `NSApp.appearance` rather than
/// SwiftUI's `.preferredColorScheme` — the AppKit route also re-themes sheets,
/// menus, the menu bar dropdown, and the Settings window, and switching back to
/// "System" takes effect immediately instead of after a relaunch.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    static let storageKey = "appearanceMode"

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    static var current: AppearanceMode {
        AppearanceMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Brand mark
//
// The logo: three server blades stepping down in width so together they form a
// "V", each with a single status LED cut out of it. Flat white on the ember brand
// gradient — deliberately simple geometry so it stays crisp at 16px. The app icon
// PNGs are rendered from exactly this geometry (see scripts/render_icon.swift).

struct BrandGlyph: Shape {
    /// Includes the LED cutouts when true (even-odd fill); a plain silhouette
    /// otherwise, which reads better at menu-bar sizes.
    var cutouts = true

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let ox = rect.midX - s / 2
        let oy = rect.midY - s / 2
        let barHeight = 0.15 * s
        let gap = 0.065 * s
        let widths: [CGFloat] = [0.76, 0.55, 0.34].map { $0 * s }
        let totalHeight = barHeight * 3 + gap * 2
        var y = oy + (s - totalHeight) / 2
        let radius = barHeight * 0.32

        var path = Path()
        for width in widths {
            let x = ox + (s - width) / 2
            let bar = CGRect(x: x, y: y, width: width, height: barHeight)
            path.addRoundedRect(in: bar, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
            if cutouts {
                let led = barHeight * 0.34
                path.addEllipse(in: CGRect(x: x + barHeight * 0.42, y: bar.midY - led / 2, width: led, height: led))
            }
            y += barHeight + gap
        }
        return path
    }
}

/// Squircle app mark used in the sidebar header, empty states and About areas.
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(Theme.brandGradient)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size / 64))
            )
            .overlay(
                BrandGlyph()
                    .fill(.white, style: FillStyle(eoFill: true))
                    .padding(size * 0.14)
            )
            .frame(width: size, height: size)
            .shadow(color: Theme.brandBottom.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

/// Template image for the menu bar extra: same blade glyph, no LEDs, drawn as a
/// template so macOS tints it for light/dark menu bars automatically.
enum MenuBarIcon {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            let path = BrandGlyph(cutouts: false).path(in: rect.insetBy(dx: 0.5, dy: 0.5))
            NSColor.black.setFill()
            NSBezierPath(cgPath: path.cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}
