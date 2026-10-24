import SwiftUI

enum SidebarSection: Hashable {
    case home
    case server(UUID)
}

enum ServerTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case projects = "Projects"
    case files = "Files"
    case terminal = "Terminal"
    case browser = "Browser"
    case pm2 = "PM2"
    case docker = "Docker"
    case network = "Network"
    case cloudflared = "Cloudflared"
    case systemd = "Systemd"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: return "server.rack"
        case .projects: return "folder.badge.gearshape"
        case .files: return "folder"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .pm2: return "bolt.horizontal.circle"
        case .docker: return "shippingbox"
        case .network: return "network"
        case .cloudflared: return "cloud"
        case .systemd: return "gearshape.2"
        }
    }

    /// ⌘1 … ⌘9, in tab-bar order (the tenth tab has none).
    var shortcut: KeyEquivalent? {
        let number = (ServerTab.allCases.firstIndex(of: self) ?? 0) + 1
        return number <= 9 ? KeyEquivalent(Character(String(number))) : nil
    }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var fleet = FleetStatus.shared
    @State private var selection: SidebarSection? = .home
    @State private var selectedTab: ServerTab = .overview
    @State private var showingSetupWizard = false
    @State private var showingQuickSwitcher = false
    @State private var showingSSHImport = false
    @State private var restartTarget: Server?
    @State private var showingRestartConfirmation = false
    @State private var showingRestartResult = false
    @State private var restartResultTitle = "Restart VPS"
    @State private var restartResultMessage = ""
    @State private var restartingServer = false
    @State private var resetTargetGroup: ServerGroup?
    @State private var transferSourceGroup: ServerGroup?
    @State private var removalTarget: Server?
    @State private var rootEnableTarget: ServerGroup?
    @AppStorage("sidebarVisible") private var sidebarVisible = true

    @State private var lastTabs: [UUID: ServerTab] = [:]

    private var selectedServerID: UUID? {
        if case let .server(id) = selection { return id }
        return nil
    }

    private func selectServer(_ id: UUID, tab: ServerTab? = nil) {
        if let tab {
            selectedTab = tab
        } else if selectedServerID != id {
            selectedTab = lastTabs[id] ?? .overview
        }
        selection = .server(id)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppHeaderBar(
                sidebarVisible: $sidebarVisible,
                onSearch: { showingQuickSwitcher = true },
                onAddServer: { showingSetupWizard = true },
                onOpenAlert: { alert in selectServer(alert.serverID, tab: alert.tab) }
            )

            HStack(spacing: 0) {
                if sidebarVisible {
                    sidebar
                        .frame(width: 248)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(Theme.stroke).frame(width: 1)
                }
                // minWidth 0 + clipped: if a tab's content ever asks for more
                // width than the window has, it gets cut off inside the detail
                // area instead of widening the whole layout (which used to shove
                // the sidebar off the left edge).
                detail
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(Theme.canvas)
            }

            AppStatusBar(selectedServer: store.server(selectedServerID))
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.canvas)
        .background(shortcutButtons)
        .sheet(isPresented: $showingSetupWizard) {
            ServerSetupWizardView { newServer in
                store.servers.append(newServer)
                selection = .server(newServer.id)
                showingSetupWizard = false
                Task { await fleet.refresh(store: store) }
            }
        }
        .sheet(isPresented: $showingSSHImport) {
            SSHConfigImportView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSSHConfigRequested)) { _ in
            showingSSHImport = true
        }
        .sheet(isPresented: $showingQuickSwitcher) {
            QuickSwitcherView { serverID, tab in
                selectServer(serverID, tab: tab)
            }
        }
        .sheet(item: $resetTargetGroup) { group in
            VPSResetWizardView(group: group)
        }
        .sheet(item: $rootEnableTarget) { group in
            VStack(spacing: 0) {
                HStack {
                    Text("Enable Root Login").font(.title2.bold())
                    Spacer()
                    Button("Close") { rootEnableTarget = nil }
                }
                .padding(20)
                Divider()
                if store.serverGroups.first(where: { $0.id == group.id })?.servers.contains(where: { $0.user == "root" }) == true {
                    ContentUnavailableView("Root Login Enabled", systemImage: "checkmark.shield.fill",
                                           description: Text("A root entry for \(group.title) was added to the sidebar. Reset and Transfer are now available."))
                } else {
                    RootLoginRequiredView(group: group, action: "Resetting or transferring")
                }
            }
            .frame(width: 560, height: 440)
        }
        .sheet(item: $transferSourceGroup) { group in
            VPSMigrationWizardView(sourceGroup: group)
        }
        .confirmationDialog("Restart the VPS at \(restartTarget?.host ?? "")?", isPresented: $showingRestartConfirmation, titleVisibility: .visible) {
            Button("Restart VPS", role: .destructive) {
                guard let target = restartTarget else { return }
                restartingServer = true
                Task {
                    defer {
                        restartingServer = false
                        restartTarget = nil
                    }
                    do {
                        try await ServerControlService.shared.restart(target)
                        restartResultTitle = "Restart requested"
                        restartResultMessage = "\(target.host):\(target.port) accepted the reboot request. SSH will be briefly unavailable while it restarts."
                    } catch {
                        restartResultTitle = "Could not restart VPS"
                        restartResultMessage = error.localizedDescription
                    }
                    showingRestartResult = true
                }
            }
            Button("Cancel", role: .cancel) { restartTarget = nil }
        } message: {
            Text("This reboots the entire host shared by all saved SSH users at \(restartTarget?.host ?? "this server").")
        }
        .confirmationDialog("Remove \(removalTarget?.nickname ?? "this server")?", isPresented: Binding(
            get: { removalTarget != nil },
            set: { if !$0 { removalTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Server", role: .destructive) {
                guard let server = removalTarget else { return }
                if selectedServerID == server.id { selection = .home }
                store.servers.removeAll { $0.id == server.id }
                store.removeData(for: [server.id])
                TerminalSessionManager.shared.closeAll(for: server.id)
                removalTarget = nil
            }
            Button("Cancel", role: .cancel) { removalTarget = nil }
        } message: {
            Text("Only removes it from VPS Manager, together with its linked projects, PM2 configs, tunnels and tracked services. Nothing on the server itself is touched.")
        }
        .alert(restartResultTitle, isPresented: $showingRestartResult) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restartResultMessage)
        }
        .onReceive(NotificationCenter.default.publisher(for: .newServerRequested)) { _ in
            showingSetupWizard = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .quickSwitcherRequested)) { _ in
            showingQuickSwitcher = true
        }
        .task {
            AutoSyncManager.shared.attach(store: store)
            HealthMonitor.shared.start(store: store)
            FleetStatus.shared.start(store: store)
            BackupManager.shared.attach(store: store)
            WindowOpener.shared.openMain = { openWindow(id: "main") }
            if let id = store.selectedServerID {
                selection = .server(id)
            }
        }
        .onChange(of: selection) { _, newValue in
            if case let .server(id) = newValue {
                // Just bookkeeping ("what was last picked, anywhere"), used to seed
                // the *next* freshly opened window's starting selection. Deliberately
                // one-directional — see `pendingServerID` for the actual deep-link path
                // that's allowed to push a navigation into this window from outside.
                store.selectedServerID = id
            }
        }
        .onChange(of: selectedTab) { _, tab in
            if let id = selectedServerID { lastTabs[id] = tab }
        }
        .onChange(of: store.pendingServerID) { _, newID in
            // Set by the menu bar or a background health alert asking THIS window
            // (and any other currently open window) to actually navigate somewhere,
            // as opposed to ordinary local selection changes, which only update the
            // bookkeeping above and don't jump other open windows around.
            if let newID {
                selection = .server(newID)
                store.pendingServerID = nil
            }
        }
        .onChange(of: store.pendingTab) { _, newTab in
            // Set by a notification tap or menu bar action to deep-link straight to
            // a specific tab (e.g. a crash notification opens directly to PM2).
            if let newTab {
                selectedTab = newTab
                store.pendingTab = nil
            }
        }
        // Registers this window with WindowOpener so anything that just wants
        // "make sure a VPS Manager window is visible" (menu bar click, Dock
        // reopen, a background alert) refocuses an existing one via
        // WindowOpener.showMain() instead of spawning a new one. Explicit user
        // requests for a new window still go through openWindow(id:) directly
        // (see the "New Window" command in App.swift).
        .background(WindowAccessor { window in
            WindowOpener.shared.register(window)
            // Belt-and-suspenders alongside AppDelegate's
            // applicationSupportsSecureRestorableState(_:) returning false: opts
            // this specific window out of AppKit's state restoration too, so a
            // quit-with-two-windows-open session can never cause launch to
            // silently restore a second window on top of the fresh one
            // WindowGroup always creates.
            window.isRestorable = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            TrafficLightPositioner.shared.attach(to: window, headerHeight: AppHeaderBar.height)
        })
    }

    /// Invisible buttons that carry this window's keyboard shortcuts: ⌘0 for the
    /// dashboard, ⌘1–⌘9 for the selected server's sections, ⌘R to refresh and
    /// ⌃⌘S to toggle the sidebar.
    ///
    /// While the remote browser is showing they stand down, so ⌘R, ⌘0 and ⌘1–⌘9
    /// keep meaning reload, reset zoom and switch tab inside the page.
    private var shortcutButtons: some View {
        let browserShowing = selectedServerID != nil && selectedTab == .browser
        return ZStack {
            Group {
                Button("") { selection = .home }
                    .keyboardShortcut("0", modifiers: .command)
                ForEach(ServerTab.allCases.filter { $0.shortcut != nil }) { tab in
                    Button("") { if selectedServerID != nil { selectedTab = tab } }
                        .keyboardShortcut(tab.shortcut!, modifiers: .command)
                }
                Button("") { Task { await fleet.refresh(store: store) } }
                    .keyboardShortcut("r", modifiers: .command)
            }
            .disabled(browserShowing)
            Button("") { withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible.toggle() } }
                .keyboardShortcut("s", modifiers: [.command, .control])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if case let .server(id) = selection, let server = store.server(id) {
            VStack(spacing: 0) {
                ServerPageHeader(server: server, selectedTab: $selectedTab) {
                    serverActionsMenu(server)
                }
                ServerDetailView(server: server, tab: selectedTab)
                    .environment(\.openServerTab, { selectedTab = $0 })
            }
        } else {
            HomeDashboardView(
                onSelectServer: { serverID, tab in selectServer(serverID, tab: tab) },
                onAddServer: { showingSetupWizard = true },
                onImport: { showingSSHImport = true }
            )
        }
    }

    // MARK: - Sidebar

    /// Custom-drawn rather than a `List(selection:)`: macOS paints native list
    /// selection in the user's *system* accent color (which overrides an app's
    /// own accent unless the system is set to Multicolor), so a List can't
    /// guarantee the brand blue.
    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarNavRow(title: "Dashboard", icon: "square.grid.2x2", isSelected: selection == .home || selection == nil) {
                    selection = .home
                }

                HStack {
                    SidebarSectionHeader(title: "Servers")
                    Spacer()
                    Menu {
                        Button("Add Server…", systemImage: "plus") { showingSetupWizard = true }
                        Button("Import from SSH Config…", systemImage: "square.and.arrow.down") { showingSSHImport = true }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add Server")
                    .padding(.top, 10)
                    .padding(.trailing, 4)
                }

                if store.servers.isEmpty {
                    Text("No servers yet. Add one to get started.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ForEach(store.serverGroups) { group in
                        if store.serverGroups.count > 1 || group.servers.count > 1 {
                            SidebarGroupHeader(title: group.title)
                        }
                        ForEach(group.servers) { server in
                            ServerSidebarRow(
                                server: server,
                                health: fleet.health(for: server.id),
                                isSelected: selectedServerID == server.id
                            ) {
                                selectServer(server.id)
                            }
                            .contextMenu { serverContextMenu(server, group: group) }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 12)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.never)
        .background(Theme.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Rectangle().fill(Theme.stroke).frame(height: 1)
                Button {
                    showingSetupWizard = true
                } label: {
                    Label("Add Server", systemImage: "plus")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(12)
            }
            .background(Theme.sidebar)
        }
    }

    @ViewBuilder
    private func serverContextMenu(_ server: Server, group: ServerGroup) -> some View {
        Menu("Open") {
            ForEach(ServerTab.allCases) { tab in
                Button(tab.rawValue, systemImage: tab.icon) { selectServer(server.id, tab: tab) }
            }
        }
        Button("Copy SSH Command", systemImage: "doc.on.doc") {
            copySSHCommand(server)
        }
        Divider()
        groupActions(server, group: group)
        Divider()
        Button("Remove Server…", systemImage: "minus.circle", role: .destructive) {
            removalTarget = server
        }
    }

    @ViewBuilder
    private func groupActions(_ server: Server, group: ServerGroup) -> some View {
        Button("Restart VPS…", systemImage: "arrow.clockwise") {
            restartTarget = group.servers.first(where: { $0.user == "root" }) ?? server
            showingRestartConfirmation = true
        }
        .disabled(restartingServer)
        // Both rewrite the whole host and must run as root (see
        // RootLoginRequiredView); say so up front rather than in the sheet.
        let hasRoot = group.servers.contains { $0.user == "root" }
        if !hasRoot {
            Button("Enable Root Login…", systemImage: "key") {
                rootEnableTarget = group
            }
        }
        Button(hasRoot ? "Transfer VPS…" : "Transfer VPS… (needs root login)", systemImage: "arrow.left.arrow.right") {
            transferSourceGroup = group
        }
        .disabled(!hasRoot)
        Button(hasRoot ? "Reset Entire VPS…" : "Reset Entire VPS… (needs root login)", systemImage: "trash", role: .destructive) {
            resetTargetGroup = group
        }
        .disabled(!hasRoot)
    }

    /// The ⋯ menu in a server's page header.
    @ViewBuilder
    private func serverActionsMenu(_ server: Server) -> some View {
        Button("Copy SSH Command", systemImage: "doc.on.doc") {
            copySSHCommand(server)
        }
        Button("Refresh Status", systemImage: "arrow.clockwise") {
            Task { await fleet.refresh(store: store) }
        }
        if let group = store.serverGroups.first(where: { $0.servers.contains(where: { $0.id == server.id }) }) {
            Divider()
            groupActions(server, group: group)
        }
        Divider()
        Button("Remove Server…", systemImage: "minus.circle", role: .destructive) {
            removalTarget = server
        }
    }

    private func copySSHCommand(_ server: Server) {
        var parts = ["ssh"]
        if server.port != 22 { parts += ["-p", "\(server.port)"] }
        if !server.identityFile.isEmpty { parts += ["-i", server.identityFile] }
        parts.append(server.sshTarget)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: " "), forType: .string)
    }
}

/// Grabs a SwiftUI view's underlying NSWindow once it's actually in the window
/// hierarchy. Standard, minimal AppKit-interop shim — SwiftUI has no direct API for
/// "give me my own window," so this reads it off an invisible helper NSView instead.
private struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Server page header

/// Title block for a server (icon, name, SSH target, live status, actions) and
/// the section tab bar underneath it.
struct ServerPageHeader<MenuContent: View>: View {
    let server: Server
    @Binding var selectedTab: ServerTab
    @ViewBuilder var menuContent: () -> MenuContent
    @ObservedObject private var fleet = FleetStatus.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(server.colorTag.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 10) {
                        Text(server.nickname)
                            .font(.title2.weight(.bold))
                            .lineLimit(1)
                        if let h = fleet.health(for: server.id) {
                            TintedPill(label: h.statusLabel, tint: h.statusTint)
                        }
                    }
                    Text(server.sshTarget + (server.port == 22 ? "" : ":\(server.port)"))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Button {
                    selectedTab = .terminal
                } label: {
                    Label("Terminal", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                Menu {
                    menuContent()
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18)
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Server actions")
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 12)

            // Full labels when they fit; otherwise the selected tab keeps its label
            // and the rest collapse to icons (with tooltips).
            ViewThatFits(in: .horizontal) {
                tabStrip(compact: false)
                tabStrip(compact: true)
            }
            .padding(.horizontal, 18)
        }
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }

    private func tabStrip(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(ServerTab.allCases) { tab in
                ServerTabButton(tab: tab, isSelected: selectedTab == tab, showsLabel: !compact || selectedTab == tab) {
                    selectedTab = tab
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct ServerTabButton: View {
    let tab: ServerTab
    let isSelected: Bool
    var showsLabel = true
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 11.5, weight: .semibold))
                    if showsLabel {
                        Text(tab.rawValue)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            .fixedSize()
                    }
                }
                .foregroundStyle(isSelected ? Theme.accent : (hovering ? Color.primary : Color.secondary))
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent.opacity(hovering && !isSelected ? 0.07 : 0))
                        .padding(.vertical, 3)
                )
                Rectangle()
                    .fill(isSelected ? Theme.accent : .clear)
                    .frame(height: 2.5)
                    .clipShape(Capsule())
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tab.shortcut.map { "\(tab.rawValue) (⌘\(String($0.character)))" } ?? tab.rawValue)
    }
}

struct ServerDetailView: View {
    let server: Server
    let tab: ServerTab

    /// Tabs that hold a live connection stay mounted (just hidden) so switching
    /// away and back keeps the SSH session, scrollback and browser intact.
    private var isPersistentTab: Bool { tab == .terminal || tab == .browser }

    var body: some View {
        ZStack {
            // Everything else is cheap to rebuild and reloads its own state.
            Group {
                switch tab {
                case .overview: ServerOverviewView(server: server)
                case .projects: ProjectListView(server: server)
                case .files: FileBrowserView(server: server)
                case .terminal, .browser: Color.clear
                case .pm2: PM2DashboardView(server: server)
                case .docker: DockerView(server: server)
                case .network: NetworkView(server: server)
                case .cloudflared: CloudflaredView(server: server)
                case .systemd: SystemdView(server: server)
                }
            }
            .opacity(isPersistentTab ? 0 : 1)
            .allowsHitTesting(!isPersistentTab)

            // Shells live in TerminalSessionManager, so they keep running across
            // tab and server switches; this view just shows the active one.
            TerminalTabView(server: server, isActive: tab == .terminal)
                .id(server.id)
                .opacity(tab == .terminal ? 1 : 0)
                .allowsHitTesting(tab == .terminal)

            // The browser session lives in RemoteBrowserManager, so even across
            // server switches it keeps running; this view just shows it.
            RemoteBrowserView(server: server, isActive: tab == .browser)
                .id(server.id)
                .opacity(tab == .browser ? 1 : 0)
                .allowsHitTesting(tab == .browser)
        }
        .background(Theme.canvas)
    }
}

// MARK: - Sidebar rows

/// A server's row in the sidebar: color-tag tile, name, user, and a live health dot.
struct ServerSidebarRow: View {
    let server: Server
    let health: FleetStatus.Health?
    let isSelected: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(server.colorTag.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.nickname)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Color.primary)
                        .lineLimit(1)
                    Text(server.user + "@" + server.host)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(health?.statusTint ?? Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .help(health?.statusLabel ?? "Not checked yet")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Theme.sidebarSelection : (hovering ? Theme.sidebarSelection.opacity(0.6) : .clear))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule().fill(Theme.accent).frame(width: 3, height: 18).offset(x: -1)
                }
            }
    }
}

/// One navigable sidebar entry; the selected row gets a soft brand-blue wash and
/// an accent bar, like Docker Desktop's navigation.
struct SidebarNavRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    var indent: CGFloat = 0
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Color.secondary)
                    .frame(width: 26)
                Text(title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.accent : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, 8 + indent)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.sidebarSelection : (hovering ? Theme.sidebarSelection.opacity(0.6) : .clear))
                    .overlay(alignment: .leading) {
                        if isSelected {
                            Capsule().fill(Theme.accent).frame(width: 3, height: 18).offset(x: -1)
                        }
                    }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SidebarSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// Host label above a set of SSH accounts that share one machine.
struct SidebarGroupHeader: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "network")
                .font(.system(size: 9, weight: .semibold))
            Text(title)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

// MARK: - Tab navigation from inside a tab

private struct OpenServerTabKey: EnvironmentKey {
    static let defaultValue: (ServerTab) -> Void = { _ in }
}

extension EnvironmentValues {
    /// Lets a tab (e.g. Overview's quick actions) switch the window to another
    /// section of the same server.
    var openServerTab: (ServerTab) -> Void {
        get { self[OpenServerTabKey.self] }
        set { self[OpenServerTabKey.self] = newValue }
    }
}
