import SwiftUI
import AppKit

// MARK: - Card container
//
// The one visual container used everywhere a "row of information with actions"
// shows up. A solid themed surface (white in light mode, deep navy in dark), a
// hairline border, and a soft shadow in light mode only — so cards read as
// raised panels on the canvas the way Docker Desktop's do, in both themes.

struct CardBackground: ViewModifier {
    var padding: CGFloat = 14
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 6, y: 2)
    }
}

extension View {
    func cardBackground(padding: CGFloat = 14) -> some View {
        modifier(CardBackground(padding: padding))
    }

    /// Fills a whole tab with the themed canvas color behind its content.
    func canvasBackground() -> some View {
        background(Theme.canvas)
    }
}

// MARK: - Icon tile
//
// A small square glyph used to anchor a card or section header — brand blue on
// a soft blue wash by default; pass a semantic tone (danger, warning) when the
// tile is conveying state.

struct IconTile: View {
    var systemImage: String
    var size: CGFloat = 30
    var tone: Color = Theme.accent

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tone)
            .frame(width: size, height: size)
            .background(tone.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

// MARK: - Status semantics
//
// One enum standing in for both a systemd ActiveState and a "reachable /
// degraded / down" server summary, so the glyph + label + color logic is
// written once: green running, grey stopped, red failed.

enum RunState {
    case running, stopped, failed, unknown, loading

    static func fromSystemd(active: String, sub: String) -> RunState {
        switch active {
        case "active": return .running
        case "failed": return .failed
        case "inactive", "deactivating": return .stopped
        default: return .unknown
        }
    }

    var symbol: String {
        switch self {
        case .running: return "circle.fill"
        case .stopped: return "circle"
        case .failed: return "exclamationmark.circle.fill"
        case .unknown: return "questionmark.circle"
        case .loading: return "circle.dotted"
        }
    }

    var label: String {
        switch self {
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        case .loading: return "Checking…"
        }
    }

    var tint: Color {
        switch self {
        case .running: return Theme.success
        case .stopped: return .secondary
        case .failed: return Theme.danger
        case .unknown, .loading: return .secondary
        }
    }
}

struct StatusPill: View {
    var state: RunState
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: state.symbol)
                .font(.system(size: 7, weight: .bold))
            Text(detail ?? state.label)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(state.tint.opacity(0.12), in: Capsule())
    }
}

extension RunState: Equatable {}

/// A dot + label capsule in any tint — for states RunState doesn't model, like
/// a server being "Degraded" (amber) rather than outright failed.
struct TintedPill: View {
    var label: String
    var tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

// MARK: - Section top bar
//
// The "N things · [actions] · [refresh]" header row repeated at the top of
// every tab. One implementation instead of four hand-rolled HStacks.

struct SectionTopBar<Actions: View>: View {
    var title: String
    var systemImage: String
    var onRefresh: (() -> Void)? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: systemImage, size: 28)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            actions
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            if let onRefresh {
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.bordered)
                .help("Refresh")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(Theme.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke.opacity(0.7)).frame(height: 1)
        }
    }
}

// MARK: - Meter
//
// A labelled horizontal usage bar (disk, memory, load). Turns amber past 75%
// and red past 90% so a glance tells you whether to worry.

struct UsageMeter: View {
    var label: String
    var fraction: Double
    var detail: String

    private var tone: Color {
        if fraction >= 0.9 { return Theme.danger }
        if fraction >= 0.75 { return Theme.warning }
        return Theme.accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label).font(.subheadline.weight(.medium))
                Spacer()
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stroke.opacity(0.7))
                    Capsule().fill(tone)
                        .frame(width: max(6, geo.size.width * min(max(fraction, 0), 1)))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Inline error banner
//
// Replaces bare red `Text(errorMessage)` with something that (a) doesn't blend
// into the background at a glance, (b) is selectable so the user can copy the
// exact remote error, and (c) can show a one-tap "Copy Fix" when the error is a
// detected sudo/password issue.

struct InlineErrorBanner: View {
    var message: String
    var copyableFix: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let copyableFix {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(copyableFix, forType: .string)
                    } label: {
                        Label("Copy Fix Command", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.3)))
    }
}

/// Pulls the `echo ... NOPASSWD:ALL ...` one-liner back out of an
/// `SSHCommandFailure`'s message so the banner's "Copy Fix" button can hand the
/// user a ready-to-paste command instead of them re-typing it from prose.
func extractSudoFixCommand(from error: Error) -> String? {
    guard let failure = error as? SSHCommandFailure, failure.isLikelySudoPasswordIssue,
          let description = failure.errorDescription else { return nil }
    for line in description.split(separator: "\n") where line.contains("NOPASSWD:ALL") {
        return line.trimmingCharacters(in: .whitespaces)
    }
    return nil
}

// MARK: - Tiny stat readout
//
// Reused label/value pairing (already the shape PM2StatusCard and
// HomeDashboardView both hand-rolled) — one version now.

struct StatReadout: View {
    var label: String
    var value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Row action spinner
//
// Swaps a card/row's action control for a small spinner while an async action
// (start/stop/restart/...) is in flight, so pressing a button gives immediate,
// honest feedback instead of looking like nothing happened until the next poll.

struct BusyOverlayModifier: ViewModifier {
    var isBusy: Bool
    func body(content: Content) -> some View {
        content
            .opacity(isBusy ? 0.45 : 1)
            .overlay {
                if isBusy {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(isBusy)
    }
}

extension View {
    func busyOverlay(_ isBusy: Bool) -> some View {
        modifier(BusyOverlayModifier(isBusy: isBusy))
    }
}