import SwiftUI

struct CloudflaredView: View {
    let server: Server
    @EnvironmentObject var store: AppStore
    @State private var showingWizard = false
    @State private var loginChecking = true
    @State private var loggedIn = false
    @State private var loginURL: String?
    @State private var errorMessage: String?
    @State private var removingRoute: TunnelRoute?
    @State private var showingImport = false
    @State private var editingTunnelID: UUID?
    @State private var unitStatuses: [String: SystemdUnitStatus] = [:]  // keyed by systemdUnit name
    @State private var busyUnits: Set<String> = []
    @State private var actionError: ActionError?

    struct ActionError: Identifiable {
        let id = UUID()
        let message: String
        let copyableFix: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionTopBar(title: "\(store.tunnels(for: server.id).count) tunnels", systemImage: "cloud") {
                Button { showingImport = true } label: { Label("Import Existing", systemImage: "arrow.down.doc") }
                    .disabled(!loggedIn)
                Button { showingWizard = true } label: { Label("New Route", systemImage: "plus") }
                    .disabled(!loggedIn)
            }
            Divider()

            if loginChecking {
                Spacer(); ProgressView("Checking cloudflared login status…"); Spacer()
            } else if !loggedIn {
                notLoggedInView
            } else if store.tunnels(for: server.id).isEmpty {
                Spacer()
                ContentUnavailableView("No Tunnels Yet", systemImage: "cloud",
                    description: Text("Create a route, or if you already set one up manually on the server, use \"Import Existing\" above."))
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let errorMessage {
                            InlineErrorBanner(message: errorMessage)
                        }
                        if let actionError {
                            InlineErrorBanner(message: actionError.message, copyableFix: actionError.copyableFix)
                        }
                        ForEach(store.tunnels(for: server.id)) { tunnel in
                            TunnelCard(
                                tunnel: tunnel,
                                routes: store.routes(for: tunnel.id),
                                status: unitStatuses[tunnel.systemdUnit],
                                isBusy: busyUnits.contains(tunnel.systemdUnit),
                                onEditConfig: { editingTunnelID = tunnel.id },
                                onRemoveRoute: { removingRoute = $0 },
                                onUnitAction: { action in Task { await perform(action, on: tunnel) } }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(isPresented: $showingWizard) {
            TunnelWizardView(server: server) { tunnel, route in
                if let idx = store.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                    store.tunnels[idx] = tunnel
                } else {
                    store.tunnels.append(tunnel)
                }
                store.routes.append(route)
                showingWizard = false
                Task { await loadUnitStatuses() }
            }
        }
        .sheet(isPresented: $showingImport) {
            ImportTunnelsView(server: server) { imported in
                for (tunnel, routes) in imported {
                    if !store.tunnels.contains(where: { $0.tunnelID == tunnel.tunnelID }) {
                        store.tunnels.append(tunnel)
                    }
                    let resolvedTunnel = store.tunnels.first(where: { $0.tunnelID == tunnel.tunnelID }) ?? tunnel
                    for route in routes where !store.routes.contains(where: { $0.tunnelID == resolvedTunnel.id && $0.hostname == route.hostname }) {
                        var r = route
                        r.tunnelID = resolvedTunnel.id
                        store.routes.append(r)
                    }
                }
                showingImport = false
                Task { await loadUnitStatuses() }
            }
        }
        .sheet(isPresented: Binding(
            get: { editingTunnelID != nil },
            set: { if !$0 { editingTunnelID = nil } }
        )) {
            if let editingTunnelID {
                TunnelConfigEditView(server: server, tunnelID: editingTunnelID)
            }
        }
        .alert("Remove this route?", isPresented: Binding(get: { removingRoute != nil }, set: { if !$0 { removingRoute = nil } })) {
            Button("Cancel", role: .cancel) { removingRoute = nil }
            Button("Remove", role: .destructive) {
                guard let route = removingRoute, let tunnel = store.tunnels.first(where: { $0.id == route.tunnelID }) else { return }
                Task {
                    do {
                        try await CloudflaredService.shared.removeRoute(server: server, configPath: tunnel.configPath, hostname: route.hostname, unit: tunnel.systemdUnit) { _ in }
                        store.routes.removeAll { $0.id == route.id }
                    } catch {
                        actionError = ActionError(message: error.localizedDescription, copyableFix: extractSudoFixCommand(from: error))
                    }
                    removingRoute = nil
                    await loadUnitStatuses()
                }
            }
        }
        .task {
            await checkLogin()
            await loadUnitStatuses()
        }
    }

    var notLoggedInView: some View {
        VStack(spacing: 16) {
            IconTile(systemImage: "cloud.fill", size: 52)
            Text("Cloudflared isn't authenticated on this server yet.")
                .font(.headline)
            Text("Log in once — it opens a Cloudflare authorization page in your browser.")
                .foregroundStyle(.secondary)
            if let loginURL {
                Link("Open Authorization Page", destination: URL(string: loginURL)!)
                    .buttonStyle(.borderedProminent)
                Text("Waiting for authorization to complete…").font(.caption).foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
            } else {
                Button("Start Login") { Task { await beginLogin() } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: 400)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func checkLogin() async {
        loginChecking = true
        do {
            loggedIn = try await CloudflaredService.shared.isLoggedIn(server)
        } catch {
            errorMessage = error.localizedDescription
        }
        loginChecking = false
    }

    /// Pulls live systemd status for every distinct unit backing this server's
    /// tunnels, so each card can show real Running/Stopped/Failed state instead of
    /// the app just assuming a tunnel it knows about is actually up.
    func loadUnitStatuses() async {
        let units = Array(Set(store.tunnels(for: server.id).map(\.systemdUnit)))
        guard !units.isEmpty else { return }
        if let statuses = try? await SystemdService.shared.statuses(server, units: units) {
            for status in statuses { unitStatuses[status.name.hasSuffix(".service") ? String(status.name.dropLast(8)) : status.name] = status }
        }
    }

    enum UnitAction { case start, stop, restart }

    func perform(_ action: UnitAction, on tunnel: CloudflareTunnel) async {
        busyUnits.insert(tunnel.systemdUnit)
        actionError = nil
        do {
            switch action {
            case .start: try await SystemdService.shared.start(server, unit: tunnel.systemdUnit)
            case .stop: try await SystemdService.shared.stop(server, unit: tunnel.systemdUnit)
            case .restart: try await SystemdService.shared.restart(server, unit: tunnel.systemdUnit)
            }
        } catch {
            actionError = ActionError(message: error.localizedDescription, copyableFix: extractSudoFixCommand(from: error))
        }
        busyUnits.remove(tunnel.systemdUnit)
        await loadUnitStatuses()
    }

    func beginLogin() async {
        do {
            try await CloudflaredService.shared.beginLogin(server) { url in
                loginURL = url
            }
            // Poll for completion every few seconds.
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let ok = try? await CloudflaredService.shared.isLoggedIn(server), ok {
                    loggedIn = true
                    loginURL = nil
                    break
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct TunnelCard: View {
    let tunnel: CloudflareTunnel
    let routes: [TunnelRoute]
    let status: SystemdUnitStatus?
    let isBusy: Bool
    var onEditConfig: () -> Void
    var onRemoveRoute: (TunnelRoute) -> Void
    var onUnitAction: (CloudflaredView.UnitAction) -> Void

    var runState: RunState {
        guard let status else { return .unknown }
        return status.activeState == "failed" ? .failed : (status.activeState == "active" ? .running : .stopped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(systemImage: "cloud", tone: runState == .failed ? Theme.danger : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tunnel.tunnelName).font(.headline)
                    Text("\(tunnel.systemdUnit) · \(tunnel.configPath)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                StatusPill(state: runState, detail: status == nil ? "Unit not found" : nil)
            }

            if !routes.isEmpty {
                VStack(spacing: 6) {
                    ForEach(routes) { route in
                        HStack {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            Text(route.hostname).font(.system(.body, design: .monospaced))
                            Text(verbatim: "→ localhost:\(route.localPort)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove", role: .destructive) { onRemoveRoute(route) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }

            Divider()

            HStack {
                Button { onEditConfig() } label: {
                    Label("Edit Config", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Spacer()
                Menu {
                    Button("Start") { onUnitAction(.start) }
                    Button("Stop") { onUnitAction(.stop) }
                    Button("Restart") { onUnitAction(.restart) }
                } label: {
                    Label("Service", systemImage: "power")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 90)
            }
        }
        .cardBackground()
        .busyOverlay(isBusy)
    }
}