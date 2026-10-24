import SwiftUI
import Charts

struct ServerOverviewView: View {
    let server: Server
    @EnvironmentObject var store: AppStore
    @Environment(\.openServerTab) private var openServerTab

    struct SystemStats {
        var hostname = ""
        var os = ""
        var kernel = ""
        var uptime = ""
        var cpuCount = 0
        var load1 = 0.0
        var load5 = 0.0
        var load15 = 0.0
        var memTotal: Double = 0     // bytes
        var memAvailable: Double = 0
        var diskTotal: Double = 0    // bytes
        var diskUsed: Double = 0
    }

    @State private var stats: SystemStats?
    @State private var loading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if loading && stats == nil {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading system stats…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardBackground(padding: 16)
                } else if let errorMessage {
                    InlineErrorBanner(message: "Could not reach server: \(errorMessage)")
                }

                if let stats {
                    resourceCards(stats)
                }

                ResourceHistoryCard(serverID: server.id)

                quickActions

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], alignment: .leading, spacing: 16) {
                    overviewCard(title: "Connection", systemImage: "network") {
                        LabeledContent("Host", value: "\(server.host):\(server.port)")
                        LabeledContent("User", value: server.user)
                        LabeledContent("Identity File", value: (server.identityFile as NSString).abbreviatingWithTildeInPath)
                        LabeledContent("Hardening") {
                            Label(server.isHardened ? "Key-only, root disabled" : "Unknown",
                                  systemImage: server.isHardened ? "checkmark.shield.fill" : "questionmark.circle")
                                .foregroundStyle(server.isHardened ? Theme.success : .secondary)
                        }
                    }

                    overviewCard(title: "System", systemImage: "cpu") {
                        if let stats {
                            if !stats.hostname.isEmpty { LabeledContent("Hostname", value: stats.hostname) }
                            if !stats.os.isEmpty { LabeledContent("OS", value: stats.os) }
                            if !stats.kernel.isEmpty { LabeledContent("Kernel", value: stats.kernel) }
                            LabeledContent("Uptime", value: stats.uptime.isEmpty ? "—" : stats.uptime)
                        } else {
                            Text(loading ? "Loading…" : "Unavailable").foregroundStyle(.secondary)
                        }
                    }

                    overviewCard(title: "Managed Here", systemImage: "square.stack.3d.up") {
                        HStack(spacing: 28) {
                            StatReadout(label: "Projects", value: "\(store.projects(for: server.id).count)")
                            StatReadout(label: "PM2 Apps", value: "\(store.pm2Configs(for: server.id).count)")
                            StatReadout(label: "Tunnels", value: "\(store.tunnels(for: server.id).count)")
                            StatReadout(label: "Services", value: "\(store.systemdUnits(for: server.id).count)")
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task {
            // Poll while the tab is on screen; each reading also feeds the
            // history chart (FleetStatus keeps it across tab switches).
            while !Task.isCancelled {
                await loadStats()
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: - Sections

    /// The server's name, address and status live in ServerPageHeader above this
    /// tab, so this is just a section title with a refresh for the live stats.
    private var header: some View {
        HStack(spacing: 10) {
            Text("At a glance")
                .font(.title3.weight(.semibold))
            if let errorMessage, !loading {
                TintedPill(label: "Offline", tint: Theme.danger)
                    .help(errorMessage)
            }
            Spacer()
            Button {
                Task { await loadStats() }
            } label: {
                if loading {
                    ProgressView().controlSize(.small).frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.bordered)
            .disabled(loading)
            .help("Refresh")
        }
    }

    private var quickActions: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 12)], spacing: 12) {
            quickAction("Terminal", "Open a shell", symbol: "terminal", tab: .terminal)
            quickAction("Browser", "Browse from the VPS", symbol: "globe", tab: .browser)
            quickAction("Files", "Browse & edit", symbol: "folder", tab: .files)
            quickAction("PM2", "Node & Python apps", symbol: "bolt.horizontal.circle", tab: .pm2)
            quickAction("Projects", "Sync local folders", symbol: "folder.badge.gearshape", tab: .projects)
            quickAction("Docker", "Containers & images", symbol: "shippingbox", tab: .docker)
            quickAction("Network", "Ports & firewall", symbol: "network", tab: .network)
            quickAction("Tunnels", "Cloudflare routes", symbol: "cloud", tab: .cloudflared)
        }
    }

    private func quickAction(_ title: String, _ subtitle: String, symbol: String, tab: ServerTab) -> some View {
        Button {
            openServerTab(tab)
        } label: {
            HStack(spacing: 12) {
                IconTile(systemImage: symbol, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.weight(.semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .cardBackground(padding: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func resourceCards(_ stats: SystemStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
            let loadFraction = stats.cpuCount > 0 ? stats.load1 / Double(stats.cpuCount) : 0
            resourceCard(symbol: "cpu", title: "CPU Load",
                         value: String(format: "%.2f", stats.load1),
                         meter: UsageMeter(label: "\(stats.cpuCount) core\(stats.cpuCount == 1 ? "" : "s")",
                                           fraction: loadFraction,
                                           detail: String(format: "%.2f · %.2f · %.2f", stats.load1, stats.load5, stats.load15)))
            let memUsed = max(0, stats.memTotal - stats.memAvailable)
            resourceCard(symbol: "memorychip", title: "Memory",
                         value: stats.memTotal > 0 ? "\(Int((memUsed / stats.memTotal * 100).rounded()))%" : "—",
                         meter: UsageMeter(label: "Used", fraction: stats.memTotal > 0 ? memUsed / stats.memTotal : 0,
                                           detail: "\(Self.bytes(memUsed)) of \(Self.bytes(stats.memTotal))"))
            resourceCard(symbol: "internaldrive", title: "Disk ( / )",
                         value: stats.diskTotal > 0 ? "\(Int((stats.diskUsed / stats.diskTotal * 100).rounded()))%" : "—",
                         meter: UsageMeter(label: "Used", fraction: stats.diskTotal > 0 ? stats.diskUsed / stats.diskTotal : 0,
                                           detail: "\(Self.bytes(stats.diskUsed)) of \(Self.bytes(stats.diskTotal))"))
        }
    }

    private func resourceCard(symbol: String, title: String, value: String, meter: UsageMeter) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(systemImage: symbol, size: 30)
                Text(title).font(.headline)
                Spacer()
                Text(value)
                    .font(.title2.monospacedDigit().weight(.bold))
                    .contentTransition(.numericText())
            }
            meter
        }
        .cardBackground(padding: 16)
    }

    @ViewBuilder
    private func overviewCard<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(systemImage: systemImage)
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .cardBackground(padding: 16)
    }

    // MARK: - Loading

    private static let statsCommand = """
    echo "H=$(hostname 2>/dev/null)"; \
    echo "O=$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") )"; \
    echo "K=$(uname -sr 2>/dev/null)"; \
    echo "U=$(uptime -p 2>/dev/null | sed 's/^up //')"; \
    echo "C=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"; \
    echo "L=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"; \
    echo "M=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print t, a}' /proc/meminfo 2>/dev/null)"; \
    echo "D=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $3}')"
    """

    func loadStats() async {
        loading = true
        defer { loading = false }
        do {
            let output = try await ShellService.shared.sshExpectingSuccess(server, command: Self.statsCommand)
            var s = SystemStats()
            for line in output.split(separator: "\n") {
                guard line.count >= 2, line.dropFirst().first == "=" else { continue }
                let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                switch line.first {
                case "H": s.hostname = value
                case "O": s.os = value
                case "K": s.kernel = value
                case "U": s.uptime = value
                case "C": s.cpuCount = Int(value) ?? 0
                case "L":
                    let parts = value.split(separator: " ").compactMap { Double($0) }
                    if parts.count == 3 { (s.load1, s.load5, s.load15) = (parts[0], parts[1], parts[2]) }
                case "M":
                    let parts = value.split(separator: " ").compactMap { Double($0) }
                    // /proc/meminfo reports kB.
                    if parts.count == 2 { (s.memTotal, s.memAvailable) = (parts[0] * 1024, parts[1] * 1024) }
                case "D":
                    let parts = value.split(separator: " ").compactMap { Double($0) }
                    // df -Pk reports 1K blocks.
                    if parts.count == 2 { (s.diskTotal, s.diskUsed) = (parts[0] * 1024, parts[1] * 1024) }
                default: break
                }
            }
            withAnimation(.easeOut(duration: 0.2)) { stats = s }
            if s.memTotal > 0 {
                FleetStatus.shared.record(.init(
                    date: Date(),
                    cpu: s.cpuCount > 0 ? s.load1 / Double(s.cpuCount) : 0,
                    memory: max(0, s.memTotal - s.memAvailable) / s.memTotal,
                    disk: s.diskTotal > 0 ? s.diskUsed / s.diskTotal : 0
                ), for: server.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

/// Line chart of CPU load, memory and disk use over time, from the readings
/// FleetStatus has collected (in memory, since launch).
private struct ResourceHistoryCard: View {
    let serverID: UUID
    @ObservedObject private var fleet = FleetStatus.shared

    enum Range: String, CaseIterable, Identifiable {
        case fifteen = "15m", hour = "1h", six = "6h"
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .fifteen: return 15 * 60
            case .hour: return 3600
            case .six: return 6 * 3600
            }
        }
    }

    @State private var range: Range = .hour

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let series: String
        let value: Double
    }

    var body: some View {
        let cutoff = Date().addingTimeInterval(-range.seconds)
        let samples = fleet.history(for: serverID).filter { $0.date >= cutoff }
        let points = samples.flatMap { sample in [
            Point(date: sample.date, series: "CPU", value: min(sample.cpu, 1.5) * 100),
            Point(date: sample.date, series: "Memory", value: sample.memory * 100),
            Point(date: sample.date, series: "Disk", value: sample.disk * 100),
        ] }

        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(systemImage: "chart.xyaxis.line")
                Text("History").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            if samples.count < 2 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Collecting readings — the chart fills in as the app keeps checking this server.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
            } else {
                Chart(points) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Percent", point.value)
                    )
                    .foregroundStyle(by: .value("Metric", point.series))
                    .interpolationMethod(.monotone)
                }
                .chartForegroundStyleScale([
                    "CPU": Theme.accent,
                    "Memory": Color.purple,
                    "Disk": Theme.warning,
                ])
                .chartYScale(domain: 0...max(100, (points.map(\.value).max() ?? 100)))
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                    }
                }
                .chartLegend(position: .top, alignment: .leading)
                .frame(height: 190)
            }
        }
        .cardBackground(padding: 16)
    }
}
