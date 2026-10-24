import Foundation
import SwiftUI

/// One shared, app-wide picture of how every server is doing: reachability, PM2
/// and systemd health, and a lightweight CPU / memory / disk snapshot. The
/// dashboard, the sidebar's status dots, the header's alerts bell and the bottom
/// status bar all read from here, so they agree with each other and a single
/// refresh updates all of them (instead of each screen polling on its own).
@MainActor
final class FleetStatus: ObservableObject {
    static let shared = FleetStatus()

    struct Health: Equatable {
        var pm2Online = 0
        var pm2Total = 0
        var systemdFailed = 0
        var systemdTotal = 0
        var reachable = true
        var loading = true

        var cpuCount = 0
        var load1 = 0.0
        var memTotal: Double = 0      // bytes
        var memAvailable: Double = 0
        var diskTotal: Double = 0     // bytes
        var diskUsed: Double = 0

        var checkedAt: Date?

        var isDegraded: Bool { systemdFailed > 0 || (pm2Total > 0 && pm2Online < pm2Total) }
        var memUsed: Double { max(0, memTotal - memAvailable) }
        var memFraction: Double { memTotal > 0 ? memUsed / memTotal : 0 }
        var diskFraction: Double { diskTotal > 0 ? diskUsed / diskTotal : 0 }
        var loadFraction: Double { cpuCount > 0 ? load1 / Double(cpuCount) : 0 }

        var runState: RunState {
            if loading { return .loading }
            if !reachable { return .failed }
            return isDegraded ? .failed : .running
        }

        var statusLabel: String {
            if loading { return "Checking…" }
            if !reachable { return "Offline" }
            return isDegraded ? "Degraded" : "Healthy"
        }

        var statusTint: Color {
            if loading { return .secondary }
            if !reachable { return Theme.danger }
            return isDegraded ? Theme.warning : Theme.success
        }
    }

    /// Something worth surfacing in the header's alerts popover.
    struct Alert: Identifiable, Hashable {
        let id: String
        let serverID: UUID
        let serverName: String
        let message: String
        let tab: ServerTab
        let symbol: String
    }

    @Published private(set) var health: [UUID: Health] = [:]
    @Published private(set) var refreshing = false
    @Published private(set) var lastRefresh: Date?

    private var autoRefreshTask: Task<Void, Never>?

    // MARK: - History

    /// A point-in-time resource reading, kept for the Overview tab's charts.
    struct Sample: Identifiable, Sendable {
        var id: Date { date }
        let date: Date
        let cpu: Double     // load ÷ cores, 0…∞ (1 = fully busy)
        let memory: Double  // 0…1
        let disk: Double    // 0…1
    }

    /// Per-server samples, oldest first, capped at `historyLimit`. In memory only:
    /// it fills up again within minutes of launching.
    @Published private(set) var history: [UUID: [Sample]] = [:]
    private let historyLimit = 360

    func history(for id: UUID) -> [Sample] { history[id] ?? [] }

    private func appendHistory(_ snapshot: Snapshot) {
        let h = snapshot.health
        guard h.reachable, h.memTotal > 0 else { return }
        record(Sample(date: h.checkedAt ?? Date(), cpu: h.loadFraction, memory: h.memFraction, disk: h.diskFraction), for: snapshot.serverID)
    }

    /// Lets a screen that polls faster than the fleet loop (the Overview tab)
    /// contribute its readings too.
    func record(_ sample: Sample, for serverID: UUID) {
        var list = history[serverID] ?? []
        if let last = list.last, sample.date.timeIntervalSince(last.date) < 5 { return }
        list.append(sample)
        if list.count > historyLimit { list.removeFirst(list.count - historyLimit) }
        history[serverID] = list
    }

    func health(for id: UUID) -> Health? { health[id] }

    /// Starts a background refresh loop (once). Safe to call from every window.
    func start(store: AppStore) {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self, weak store] in
            while !Task.isCancelled {
                guard let self, let store else { return }
                await self.refresh(store: store)
                try? await Task.sleep(for: .seconds(120))
            }
        }
    }

    func refresh(store: AppStore) async {
        guard !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            lastRefresh = Date()
        }
        let currentIDs = Set(store.servers.map(\.id))
        health = health.filter { currentIDs.contains($0.key) }
        for server in store.servers where health[server.id] == nil {
            health[server.id] = Health()
        }
        let targets = store.servers.map { ($0, store.systemdUnits(for: $0.id)) }
        await withTaskGroup(of: Snapshot.self) { group in
            for (server, units) in targets {
                group.addTask { await Self.fetch(server, units: units) }
            }
            for await snapshot in group {
                withAnimation(.easeOut(duration: 0.2)) { health[snapshot.serverID] = snapshot.health }
                appendHistory(snapshot)
                if let server = store.server(snapshot.serverID) {
                    HealthMonitor.shared.ingest(snapshot, server: server)
                }
            }
        }
    }

    func alerts(in store: AppStore) -> [Alert] {
        var result: [Alert] = []
        for server in store.servers {
            guard let h = health[server.id], !h.loading else { continue }
            if !h.reachable {
                result.append(Alert(id: "\(server.id)-offline", serverID: server.id, serverName: server.nickname,
                                    message: "Unreachable over SSH", tab: .overview, symbol: "wifi.slash"))
                continue
            }
            if h.pm2Total > h.pm2Online {
                let down = h.pm2Total - h.pm2Online
                result.append(Alert(id: "\(server.id)-pm2", serverID: server.id, serverName: server.nickname,
                                    message: "\(down) PM2 app\(down == 1 ? "" : "s") not online", tab: .pm2, symbol: "bolt.horizontal.circle"))
            }
            if h.systemdFailed > 0 {
                result.append(Alert(id: "\(server.id)-systemd", serverID: server.id, serverName: server.nickname,
                                    message: "\(h.systemdFailed) service\(h.systemdFailed == 1 ? "" : "s") failed", tab: .systemd, symbol: "gearshape.2"))
            }
            if h.diskFraction >= 0.9 {
                result.append(Alert(id: "\(server.id)-disk", serverID: server.id, serverName: server.nickname,
                                    message: "Disk \(Int(h.diskFraction * 100))% full", tab: .overview, symbol: "internaldrive"))
            }
            if h.memTotal > 0 && h.memFraction >= 0.9 {
                result.append(Alert(id: "\(server.id)-mem", serverID: server.id, serverName: server.nickname,
                                    message: "Memory \(Int(h.memFraction * 100))% used", tab: .overview, symbol: "memorychip"))
            }
        }
        return result
    }

    // MARK: - Fetching

    private static let resourceCommand = """
    echo "C=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"; \
    echo "L=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)"; \
    echo "M=$(awk '/^MemTotal:/ {t=$2} /^MemAvailable:/ {a=$2} END {print t, a}' /proc/meminfo 2>/dev/null)"; \
    echo "D=$(df -Pk / 2>/dev/null | awk 'NR==2 {print $2, $3}')"
    """

    /// One server's poll result: the summary plus the raw per-process / per-unit
    /// states HealthMonitor needs to notice individual transitions.
    struct Snapshot: Sendable {
        let serverID: UUID
        let health: Health
        let pm2: [PM2ProcessStatus]
        let systemd: [SystemdUnitStatus]
    }

    private nonisolated static func fetch(_ server: Server, units: [String]) async -> Snapshot {
        let h = await fetchHealth(server, units: units)
        return Snapshot(serverID: server.id, health: h.0, pm2: h.1, systemd: h.2)
    }

    private nonisolated static func fetchHealth(_ server: Server, units: [String]) async -> (Health, [PM2ProcessStatus], [SystemdUnitStatus]) {
        var h = Health()
        var pm2Statuses: [PM2ProcessStatus] = []
        var unitStatuses: [SystemdUnitStatus] = []
        h.loading = false
        h.checkedAt = Date()
        // Deliberately no `restartConnection` here: tearing down the shared SSH
        // master on every refresh also killed any terminal session or port
        // forward multiplexed over it. ShellService.ssh already drops a stale
        // control socket and retries on its own.
        guard let probe = try? await ShellService.shared.ssh(server, command: resourceCommand, timeout: 15), probe.success else {
            h.reachable = false
            return (h, [], [])
        }
        for line in probe.stdout.split(separator: "\n") {
            guard line.count >= 2, line.dropFirst().first == "=" else { continue }
            let value = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let numbers = value.split(separator: " ").compactMap { Double($0) }
            switch line.first {
            case "C": h.cpuCount = Int(value) ?? 0
            case "L": h.load1 = numbers.first ?? 0
            case "M": if numbers.count == 2 { (h.memTotal, h.memAvailable) = (numbers[0] * 1024, numbers[1] * 1024) }
            case "D": if numbers.count == 2 { (h.diskTotal, h.diskUsed) = (numbers[0] * 1024, numbers[1] * 1024) }
            default: break
            }
        }
        if let pm2 = try? await PM2Service.shared.fetchStatuses(server) {
            pm2Statuses = pm2
            h.pm2Total = pm2.count
            h.pm2Online = pm2.filter { $0.status == "online" }.count
        }
        if !units.isEmpty, let statuses = try? await SystemdService.shared.statuses(server, units: units) {
            unitStatuses = statuses
            h.systemdTotal = statuses.count
            h.systemdFailed = statuses.filter { $0.activeState == "failed" }.count
        }
        return (h, pm2Statuses, unitStatuses)
    }

    static func bytes(_ value: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}
