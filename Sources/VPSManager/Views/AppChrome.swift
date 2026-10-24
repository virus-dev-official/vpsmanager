import SwiftUI
import AppKit

// MARK: - Header bar
//
// The full-width brand band across the top of every main window (the window's
// own title bar is hidden — see App.swift). Left: sidebar toggle and wordmark.
// Centre: a search field that opens the quick switcher. Right: add server,
// alerts, appearance, help and settings.

struct AppHeaderBar: View {
    static let height: CGFloat = 52

    @EnvironmentObject var store: AppStore
    @ObservedObject private var fleet = FleetStatus.shared
    @Binding var sidebarVisible: Bool
    var onSearch: () -> Void
    var onAddServer: () -> Void
    var onOpenAlert: (FleetStatus.Alert) -> Void

    @State private var showingAlerts = false
    @State private var showingHelp = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue

    var body: some View {
        ZStack {
            HStack(spacing: 6) {
                // Room for the traffic lights, which TrafficLightPositioner centres
                // vertically inside this bar.
                Color.clear.frame(width: 70, height: 1)

                HeaderIconButton(systemImage: "sidebar.left", help: "Toggle Sidebar (⌃⌘S)") {
                    withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() }
                }

                HStack(spacing: 9) {
                    BrandMark(size: 24)
                    Text("VPS Manager")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .fixedSize()
                    Text("v\(Bundle.main.shortVersion)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(.white.opacity(0.16), in: Capsule())
                        .fixedSize()
                }
                .padding(.leading, 6)
                .allowsHitTesting(false)

                Spacer(minLength: 16)

                HStack(spacing: 2) {
                    HeaderIconButton(systemImage: "plus", help: "Add Server (⌘N)", action: onAddServer)

                    let alerts = fleet.alerts(in: store)
                    HeaderIconButton(systemImage: alerts.isEmpty ? "bell" : "bell.badge", help: "Alerts", badge: alerts.count) {
                        showingAlerts.toggle()
                    }
                    .popover(isPresented: $showingAlerts, arrowEdge: .bottom) {
                        AlertsPopover(alerts: alerts) { alert in
                            showingAlerts = false
                            onOpenAlert(alert)
                        }
                    }

                    Menu {
                        Picker("Appearance", selection: $appearanceRaw) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HeaderIconLabel(systemImage: (AppearanceMode(rawValue: appearanceRaw) ?? .system).icon)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Appearance")
                    .onChange(of: appearanceRaw) { _, raw in
                        (AppearanceMode(rawValue: raw) ?? .system).apply()
                    }

                    HeaderIconButton(systemImage: "questionmark.circle", help: "Keyboard Shortcuts") {
                        showingHelp.toggle()
                    }
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                        ShortcutsPopover()
                    }

                    SettingsLink {
                        HeaderIconLabel(systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("Settings (⌘,)")
                }
                .padding(.trailing, 12)
            }

            HeaderSearchField(action: onSearch)
                .frame(maxWidth: 380)
                .padding(.horizontal, 300)
        }
        .frame(height: Self.height)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                Theme.headerGradient
                WindowDragArea()
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(.black.opacity(0.25)).frame(height: 1)
        }
    }
}

/// Looks like a search field; opens the quick switcher (⌘K) when clicked.
struct HeaderSearchField: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                Text("Search servers, apps, tunnels…")
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("⌘K")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.45)))
            }
            .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.78))
            .padding(.horizontal, 11)
            .frame(height: 30)
            .frame(minWidth: 180)
            .background(.white.opacity(hovering ? 0.2 : 0.13), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct HeaderIconLabel: View {
    var systemImage: String
    var badge: Int = 0
    var hovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(hovering ? 1 : 0.88))
            .frame(width: 32, height: 30)
            .background(.white.opacity(hovering ? 0.16 : 0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text(badge > 9 ? "9+" : "\(badge)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 15, minHeight: 15)
                        .background(Theme.danger, in: Capsule())
                        .offset(x: 1, y: -1)
                }
            }
            .contentShape(Rectangle())
    }
}

struct HeaderIconButton: View {
    var systemImage: String
    var help: String
    var badge: Int = 0
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HeaderIconLabel(systemImage: systemImage, badge: badge, hovering: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct AlertsPopover: View {
    let alerts: [FleetStatus.Alert]
    var onSelect: (FleetStatus.Alert) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Alerts").font(.headline)
                Spacer()
                if !alerts.isEmpty {
                    Text("\(alerts.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Theme.danger, in: Capsule())
                }
            }
            .padding(14)
            Divider()
            if alerts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.success)
                    Text("All systems healthy").font(.callout.weight(.medium))
                    Text("Servers are checked every couple of minutes.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(alerts) { alert in
                            AlertRow(alert: alert) { onSelect(alert) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(width: 320)
    }
}

private struct AlertRow: View {
    let alert: FleetStatus.Alert
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(systemImage: alert.symbol, size: 28, tone: Theme.danger)
                VStack(alignment: .leading, spacing: 1) {
                    Text(alert.serverName).font(.callout.weight(.semibold))
                    Text(alert.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(Theme.accent.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct ShortcutsPopover: View {
    private let shortcuts: [(String, String)] = [
        ("Quick switcher", "⌘K"),
        ("Add server", "⌘N"),
        ("New window", "⇧⌘N"),
        ("Dashboard", "⌘0"),
        ("Server sections", "⌘1 – ⌘9"),
        ("Import from SSH config", "⇧⌘I"),
        ("Toggle sidebar", "⌃⌘S"),
        ("Refresh status", "⌘R"),
        ("Settings", "⌘,"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text("VPS Manager").font(.headline)
                    Text("Version \(Bundle.main.shortVersion)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            Divider()
            VStack(spacing: 7) {
                ForEach(shortcuts, id: \.0) { item in
                    HStack {
                        Text(item.0).font(.callout)
                        Spacer()
                        Text(item.1)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
                    }
                }
            }
            .padding(14)
        }
        .frame(width: 280)
    }
}

// MARK: - Status bar
//
// Docker-Desktop-style footer: overall fleet state on the left, the selected
// server's live resources in the middle, last check + refresh on the right.

struct AppStatusBar: View {
    static let height: CGFloat = 28

    @EnvironmentObject var store: AppStore
    @ObservedObject private var fleet = FleetStatus.shared
    var selectedServer: Server?

    var body: some View {
        HStack(spacing: 14) {
            fleetSummary

            if let server = selectedServer, let h = fleet.health(for: server.id), !h.loading, h.reachable {
                Divider().frame(height: 12)
                Text(server.nickname)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if h.cpuCount > 0 {
                    metric("CPU", String(format: "%.2f load · %d core%@", h.load1, h.cpuCount, h.cpuCount == 1 ? "" : "s"), h.loadFraction)
                }
                if h.memTotal > 0 {
                    metric("RAM", "\(FleetStatus.bytes(h.memUsed)) / \(FleetStatus.bytes(h.memTotal))", h.memFraction)
                }
                if h.diskTotal > 0 {
                    metric("Disk", "\(FleetStatus.bytes(h.diskUsed)) / \(FleetStatus.bytes(h.diskTotal))", h.diskFraction)
                }
            }

            Spacer(minLength: 8)

            if let last = fleet.lastRefresh {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Checked \(last.formatted(.relative(presentation: .named)))")
                        .lineLimit(1)
                }
            }
            Button {
                Task { await fleet.refresh(store: store) }
            } label: {
                if fleet.refreshing {
                    ProgressView().controlSize(.mini)
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 14, height: 14)
                }
            }
            .buttonStyle(.plain)
            .disabled(fleet.refreshing)
            .help("Refresh status (⌘R)")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(Theme.statusBar)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private var fleetSummary: some View {
        let healths = store.servers.compactMap { fleet.health(for: $0.id) }.filter { !$0.loading }
        let online = healths.filter(\.reachable).count
        let tint: Color
        let label: String
        if store.servers.isEmpty {
            tint = .secondary
            label = "No servers"
        } else if healths.count < store.servers.count {
            tint = Theme.accent
            label = "Checking servers…"
        } else if online == healths.count {
            tint = Theme.success
            label = online == 1 ? "1 server online" : "All \(online) servers online"
        } else {
            tint = online == 0 ? Theme.danger : Theme.warning
            label = "\(online) of \(healths.count) servers online"
        }
        return HStack(spacing: 6) {
            Circle().fill(tint).frame(width: 7, height: 7)
                .shadow(color: tint.opacity(0.6), radius: 3)
            Text(label)
                .fontWeight(.medium)
                .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        }
    }

    private func metric(_ label: String, _ value: String, _ fraction: Double) -> some View {
        HStack(spacing: 5) {
            Text(label).fontWeight(.semibold)
            Text(value)
                .monospacedDigit()
                .foregroundStyle(fraction >= 0.9 ? Theme.danger : fraction >= 0.75 ? Theme.warning : .secondary)
        }
        .lineLimit(1)
    }
}

// MARK: - Window plumbing

/// Makes the custom header behave like a real title bar: drag to move the
/// window, double-click to zoom (or minimise, per the user's system setting).
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" {
                    window?.performMiniaturize(nil)
                } else if action != "None" {
                    window?.performZoom(nil)
                }
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Re-centres the window's traffic lights inside the taller custom header. AppKit
/// lays the title bar out again on resize and full-screen transitions, so the
/// position is re-applied on each of those.
@MainActor
final class TrafficLightPositioner {
    static let shared = TrafficLightPositioner()
    private let attached = NSHashTable<NSWindow>.weakObjects()

    func attach(to window: NSWindow, headerHeight: CGFloat, leading: CGFloat = 18) {
        apply(window, headerHeight: headerHeight, leading: leading)
        guard !attached.contains(window) else { return }
        attached.add(window)
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    self.apply(window, headerHeight: headerHeight, leading: leading)
                }
            }
        }
        // AppKit also re-lays out the title bar on its own (first display, theme
        // changes, toolbar/full-screen bookkeeping), snapping the buttons back to
        // the top edge. Watch the title bar container's frame and re-apply.
        if let container = window.standardWindowButton(.closeButton)?.superview?.superview {
            container.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: container, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window, !self.applying else { return }
                    self.apply(window, headerHeight: headerHeight, leading: leading)
                }
            }
        }
        // And once more after the first layout pass has settled.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window else { return }
            self.apply(window, headerHeight: headerHeight, leading: leading)
        }
    }

    private var applying = false

    private func apply(_ window: NSWindow, headerHeight: CGFloat, leading: CGFloat) {
        applying = true
        defer { applying = false }
        guard !window.styleMask.contains(.fullScreen),
              let close = window.standardWindowButton(.closeButton),
              let mini = window.standardWindowButton(.miniaturizeButton),
              let zoom = window.standardWindowButton(.zoomButton),
              let container = close.superview?.superview else { return }

        var frame = container.frame
        frame.size.height = headerHeight
        frame.origin.y = window.frame.height - headerHeight
        if container.frame != frame { container.frame = frame }

        let spacing = mini.frame.minX - close.frame.minX
        let y = (headerHeight - close.frame.height) / 2
        for (index, button) in [close, mini, zoom].enumerated() {
            button.setFrameOrigin(NSPoint(x: leading + CGFloat(index) * (spacing > 0 ? spacing : 20), y: y))
        }
    }
}

extension Bundle {
    var shortVersion: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
    }
}
