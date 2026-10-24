import SwiftUI

struct HomeDashboardView: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var fleet = FleetStatus.shared
    var onSelectServer: (UUID, ServerTab) -> Void
    var onAddServer: () -> Void
    var onImport: () -> Void = {}

    enum Layout: String { case grid, table }
    @AppStorage("dashboardLayout") private var layoutRaw = Layout.grid.rawValue
    @State private var filter = ""

    private var layout: Layout { Layout(rawValue: layoutRaw) ?? .grid }

    private var filteredGroups: [ServerGroup] {
        guard !filter.isEmpty else { return store.serverGroups }
        return store.serverGroups.compactMap { group in
            let matches = group.servers.filter {
                $0.nickname.localizedCaseInsensitiveContains(filter)
                    || $0.host.localizedCaseInsensitiveContains(filter)
                    || $0.user.localizedCaseInsensitiveContains(filter)
            }
            return matches.isEmpty ? nil : ServerGroup(id: group.id, host: group.host, port: group.port, servers: matches)
        }
    }

    var body: some View {
        Group {
            if store.servers.isEmpty {
                welcome
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header
                        statsRow
                        toolbar
                        if filteredGroups.isEmpty {
                            ContentUnavailableView.search(text: filter)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                        } else if layout == .grid {
                            grid
                        } else {
                            table
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 1280, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.canvas)
    }

    // MARK: - Header & stats

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Dashboard")
                    .font(.system(size: 26, weight: .bold))
                Text("Health of every server at a glance.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await fleet.refresh(store: store) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(fleet.refreshing)
            Button(action: onAddServer) {
                Label("Add Server", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var statsRow: some View {
        let loaded = store.servers.compactMap { fleet.health(for: $0.id) }.filter { !$0.loading }
        let reachable = loaded.filter(\.reachable)
        let pm2Online = reachable.reduce(0) { $0 + $1.pm2Online }
        let pm2Total = reachable.reduce(0) { $0 + $1.pm2Total }
        let alerts = fleet.alerts(in: store).count
        let stillLoading = loaded.count < store.servers.count

        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
            statCard("Servers", value: "\(store.servers.count)", caption: "\(store.serverGroups.count) host\(store.serverGroups.count == 1 ? "" : "s")",
                     symbol: "server.rack", tone: Theme.accent)
            statCard("Reachable", value: stillLoading ? "…" : "\(reachable.count)/\(loaded.count)", caption: "over SSH",
                     symbol: "wifi", tone: !stillLoading && reachable.count < loaded.count ? Theme.warning : Theme.success)
            statCard("PM2 Online", value: stillLoading ? "…" : (pm2Total == 0 ? "—" : "\(pm2Online)/\(pm2Total)"), caption: "processes",
                     symbol: "bolt.horizontal.circle", tone: Theme.accent)
            statCard("Alerts", value: stillLoading ? "…" : "\(alerts)", caption: alerts == 0 ? "all clear" : "need attention",
                     symbol: alerts > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                     tone: alerts > 0 ? Theme.danger : Theme.success)
        }
    }

    private func statCard(_ label: String, value: String, caption: String, symbol: String, tone: Color) -> some View {
        HStack(spacing: 14) {
            IconTile(systemImage: symbol, size: 42, tone: tone)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .cardBackground(padding: 16)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Servers")
                .font(.title3.weight(.semibold))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter servers", text: $filter)
                    .textFieldStyle(.plain)
                if !filter.isEmpty {
                    Button {
                        filter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))

            Picker("Layout", selection: $layoutRaw) {
                Image(systemName: "square.grid.2x2").tag(Layout.grid.rawValue)
                Image(systemName: "list.bullet").tag(Layout.table.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Cards or table")
        }
    }

    // MARK: - Grid

    private var grid: some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(filteredGroups) { group in
                VStack(alignment: .leading, spacing: 12) {
                    groupHeader(group)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], spacing: 16) {
                        ForEach(group.servers) { server in
                            ServerCard(server: server, health: fleet.health(for: server.id),
                                       projectCount: store.projects(for: server.id).count,
                                       onOpen: { onSelectServer(server.id, $0) })
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(_ group: ServerGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "network")
                .foregroundStyle(Theme.accent)
            Text(group.title)
                .font(.callout.weight(.semibold).monospaced())
            Text("\(group.servers.count) account\(group.servers.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Table

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Name").frame(maxWidth: .infinity, alignment: .leading)
                Text("Status").frame(width: 96, alignment: .leading)
                Text("CPU").frame(width: 90, alignment: .leading)
                Text("Memory").frame(width: 90, alignment: .leading)
                Text("Disk").frame(width: 90, alignment: .leading)
                Text("PM2").frame(width: 50, alignment: .leading)
                Text("Actions").frame(width: 110, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.surfaceAlt)

            ForEach(filteredGroups.flatMap(\.servers)) { server in
                Rectangle().fill(Theme.stroke).frame(height: 1)
                ServerTableRow(server: server, health: fleet.health(for: server.id),
                               onOpen: { onSelectServer(server.id, $0) })
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }

    // MARK: - Empty state

    private var welcome: some View {
        VStack(spacing: 22) {
            BrandMark(size: 88)
            VStack(spacing: 8) {
                Text("Welcome to VPS Manager")
                    .font(.system(size: 30, weight: .bold))
                Text("Add a server to manage projects, files, processes and tunnels — and browse the web from it.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }
            HStack(spacing: 10) {
                Button(action: onAddServer) {
                    Label("Add Your First Server", systemImage: "plus")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                Button(action: onImport) {
                    Label("Import from SSH Config", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)

            HStack(spacing: 14) {
                featureTile("terminal", "Terminal", "Native SSH shell")
                featureTile("arrow.triangle.2.circlepath", "Project Sync", "Diff, then push")
                featureTile("bolt.horizontal.circle", "PM2", "Deploy & monitor")
                featureTile("cloud", "Tunnels", "Cloudflare routes")
            }
            .padding(.top, 10)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func featureTile(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 8) {
            IconTile(systemImage: symbol, size: 36)
            Text(title).font(.callout.weight(.semibold))
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 130)
        .cardBackground(padding: 14)
    }
}

// MARK: - Server card

private struct ServerCard: View {
    let server: Server
    let health: FleetStatus.Health?
    let projectCount: Int
    var onOpen: (ServerTab) -> Void
    @State private var hovering = false

    var body: some View {
        let h = health ?? FleetStatus.Health()
        let live = !h.loading && h.reachable
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(server.colorTag.color.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.nickname)
                        .font(.headline)
                        .lineLimit(1)
                    Text("\(server.user)@\(server.host)\(server.port == 22 ? "" : ":\(server.port)")")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                TintedPill(label: h.statusLabel, tint: h.statusTint)
            }

            VStack(spacing: 9) {
                MiniMeter(label: "CPU", fraction: live ? h.loadFraction : 0,
                          detail: live && h.cpuCount > 0 ? String(format: "%.2f load", h.load1) : "—")
                MiniMeter(label: "RAM", fraction: live ? h.memFraction : 0,
                          detail: live && h.memTotal > 0 ? "\(FleetStatus.bytes(h.memUsed)) / \(FleetStatus.bytes(h.memTotal))" : "—")
                MiniMeter(label: "Disk", fraction: live ? h.diskFraction : 0,
                          detail: live && h.diskTotal > 0 ? "\(FleetStatus.bytes(h.diskUsed)) / \(FleetStatus.bytes(h.diskTotal))" : "—")
            }

            HStack(spacing: 0) {
                metric("PM2", value: live ? (h.pm2Total == 0 ? "None" : "\(h.pm2Online)/\(h.pm2Total)") : "—",
                       warn: live && h.pm2Total > 0 && h.pm2Online < h.pm2Total)
                Divider().frame(height: 26)
                metric("Services", value: live ? (h.systemdTotal == 0 ? "None" : "\(h.systemdTotal - h.systemdFailed)/\(h.systemdTotal)") : "—",
                       warn: live && h.systemdFailed > 0)
                Divider().frame(height: 26)
                metric("Projects", value: "\(projectCount)", warn: false)
            }
            .padding(.vertical, 7)
            .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            HStack(spacing: 6) {
                quickAction("Terminal", symbol: "terminal", tab: .terminal)
                quickAction("Browser", symbol: "globe", tab: .browser)
                quickAction("Files", symbol: "folder", tab: .files)
                quickAction("PM2", symbol: "bolt.horizontal.circle", tab: .pm2)
                Spacer(minLength: 0)
                Button {
                    onOpen(.overview)
                } label: {
                    Label("Open", systemImage: "arrow.right")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .cardBackground(padding: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.accent.opacity(hovering ? 0.45 : 0), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture { onOpen(.overview) }
    }

    private func metric(_ label: String, value: String, warn: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(warn ? Theme.danger : .primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func quickAction(_ title: String, symbol: String, tab: ServerTab) -> some View {
        Button {
            onOpen(tab)
        } label: {
            Image(systemName: symbol)
                .frame(width: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("Open \(title)")
    }
}

/// Compact label · bar · value row used on dashboard cards.
private struct MiniMeter: View {
    var label: String
    var fraction: Double
    var detail: String

    private var tone: Color {
        if fraction >= 0.9 { return Theme.danger }
        if fraction >= 0.75 { return Theme.warning }
        return Theme.accent
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.stroke.opacity(0.7))
                    Capsule().fill(tone)
                        .frame(width: fraction > 0 ? max(4, geo.size.width * min(fraction, 1)) : 0)
                }
            }
            .frame(height: 5)
            Text(detail)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
                .lineLimit(1)
        }
    }
}

// MARK: - Table row

private struct ServerTableRow: View {
    let server: Server
    let health: FleetStatus.Health?
    var onOpen: (ServerTab) -> Void
    @State private var hovering = false

    var body: some View {
        let h = health ?? FleetStatus.Health()
        let live = !h.loading && h.reachable
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(server.colorTag.color.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.nickname).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(server.sshTarget).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TintedPill(label: h.statusLabel, tint: h.statusTint)
                .frame(width: 96, alignment: .leading)
            percent(live && h.cpuCount > 0 ? h.loadFraction : nil).frame(width: 90, alignment: .leading)
            percent(live && h.memTotal > 0 ? h.memFraction : nil).frame(width: 90, alignment: .leading)
            percent(live && h.diskTotal > 0 ? h.diskFraction : nil).frame(width: 90, alignment: .leading)
            Text(live ? (h.pm2Total == 0 ? "—" : "\(h.pm2Online)/\(h.pm2Total)") : "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(live && h.pm2Online < h.pm2Total ? Theme.danger : .primary)
                .frame(width: 50, alignment: .leading)
            HStack(spacing: 4) {
                rowAction("terminal", "Terminal", .terminal)
                rowAction("folder", "Files", .files)
                rowAction("arrow.right.circle", "Open", .overview)
            }
            .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.accent.opacity(hovering ? 0.05 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { onOpen(.overview) }
    }

    @ViewBuilder
    private func percent(_ fraction: Double?) -> some View {
        if let fraction {
            let tone = fraction >= 0.9 ? Theme.danger : fraction >= 0.75 ? Theme.warning : Color.primary
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(tone)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func rowAction(_ symbol: String, _ title: String, _ tab: ServerTab) -> some View {
        Button {
            onOpen(tab)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
    }
}
