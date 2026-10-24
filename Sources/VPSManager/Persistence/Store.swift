import Foundation
import Combine

/// Simple JSON-file persistence under ~/Library/Application Support/VPSManager/
final class DiskStore {
    static let shared = DiskStore()
    private let root: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        root = support.appendingPathComponent("VPSManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func url(_ name: String) -> URL { root.appendingPathComponent(name) }

    func load<T: Decodable>(_ name: String, as type: T.Type, default def: T) -> T {
        let file = url(name)
        guard let data = try? Data(contentsOf: file) else { return def }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601   // must match save()'s .iso8601 encoding strategy, or every
                                               // decode silently fails (every model has a Date field) and
                                               // load() falls back to `def` — this was the actual bug.
        return (try? dec.decode(T.self, from: data)) ?? def
    }

    func save<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value) else { return }
        try? data.write(to: url(name), options: .atomic)
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var servers: [Server] = [] { didSet { DiskStore.shared.save(servers, to: "servers.json") } }
    @Published var projects: [Project] = [] { didSet { DiskStore.shared.save(projects, to: "projects.json") } }

    /// PM2 env vars are the one place in this app likely to hold real secrets (DB
    /// passwords, API keys, JWT secrets), so they're kept OUT of the plaintext JSON
    /// entirely and stored in the macOS Keychain instead, keyed by config id. The
    /// in-memory array still holds real values (needed for the UI and for
    /// generating ecosystem.config.js), but what actually hits disk always has
    /// env stripped.
    @Published var pm2Configs: [PM2AppConfig] = [] {
        didSet {
            for config in pm2Configs {
                SecretsStore.saveEnv(config.env, for: config.id)
            }
            let currentIDs = Set(pm2Configs.map(\.id))
            for removedID in Set(oldValue.map(\.id)).subtracting(currentIDs) {
                SecretsStore.deleteEnv(for: removedID)
            }
            let sanitized = pm2Configs.map { cfg -> PM2AppConfig in
                var c = cfg
                c.env = [:]
                return c
            }
            DiskStore.shared.save(sanitized, to: "pm2configs.json")
        }
    }

    @Published var tunnels: [CloudflareTunnel] = [] { didSet { DiskStore.shared.save(tunnels, to: "tunnels.json") } }
    @Published var routes: [TunnelRoute] = [] { didSet { DiskStore.shared.save(routes, to: "routes.json") } }
    @Published var trackedSystemdUnits: [TrackedSystemdUnit] = [] { didSet { DiskStore.shared.save(trackedSystemdUnits, to: "systemd_units.json") } }

    @Published var selectedServerID: UUID?
    /// One-shot deep-link signal: set by the menu bar or a background health alert
    /// when they want to actually navigate somewhere (as opposed to
    /// `selectedServerID`, which just remembers the last selection so a freshly
    /// opened window has a sensible starting point). Kept separate from
    /// `selectedServerID` so that, now that multiple windows can be open at once,
    /// picking a server in one window doesn't yank every other open window's
    /// sidebar selection along with it — only an explicit deep-link request does
    /// that. Not persisted — consumed and cleared immediately by ContentView.
    @Published var pendingServerID: UUID?
    /// Transient signal used to deep-link a notification tap or menu bar action to
    /// a specific tab once the main window is focused. Not persisted — it's
    /// consumed and cleared immediately by ContentView.
    @Published var pendingTab: ServerTab?

    init() {
        servers = DiskStore.shared.load("servers.json", as: [Server].self, default: [])
        projects = DiskStore.shared.load("projects.json", as: [Project].self, default: [])

        let sanitizedPM2 = DiskStore.shared.load("pm2configs.json", as: [PM2AppConfig].self, default: [])
        pm2Configs = sanitizedPM2.map { cfg in
            var c = cfg
            c.env = SecretsStore.loadEnv(for: cfg.id) // rehydrate from Keychain
            return c
        }

        tunnels = DiskStore.shared.load("tunnels.json", as: [CloudflareTunnel].self, default: [])
        routes = DiskStore.shared.load("routes.json", as: [TunnelRoute].self, default: [])
        trackedSystemdUnits = DiskStore.shared.load("systemd_units.json", as: [TrackedSystemdUnit].self, default: [])
        selectedServerID = servers.first?.id
    }

    func projects(for serverID: UUID) -> [Project] { projects.filter { $0.serverID == serverID } }
    func pm2Configs(for serverID: UUID) -> [PM2AppConfig] { pm2Configs.filter { $0.serverID == serverID } }
    func tunnels(for serverID: UUID) -> [CloudflareTunnel] { tunnels.filter { $0.serverID == serverID } }
    func routes(for tunnelID: UUID) -> [TunnelRoute] { routes.filter { $0.tunnelID == tunnelID } }

    var serverGroups: [ServerGroup] {
        Dictionary(grouping: servers, by: \.hostGroupKey).values.compactMap { members in
            guard let first = members.first else { return nil }
            return ServerGroup(
                id: first.hostGroupKey,
                host: first.host.trimmingCharacters(in: .whitespacesAndNewlines),
                port: first.port,
                servers: members.sorted { $0.nickname.localizedStandardCompare($1.nickname) == .orderedAscending }
            )
        }
        .sorted {
            let hostOrder = $0.host.localizedStandardCompare($1.host)
            return hostOrder == .orderedSame ? $0.port < $1.port : hostOrder == .orderedAscending
        }
    }

    /// Tracked systemd unit names for a server. Seeds the built-in defaults the
    /// first time a server is looked at (and only then), so a server that already
    /// had custom units removed doesn't have defaults silently re-added.
    func systemdUnits(for serverID: UUID) -> [String] {
        if !trackedSystemdUnits.contains(where: { $0.serverID == serverID }) {
            trackedSystemdUnits.append(contentsOf: SystemdService.shared.defaultUnits.map {
                TrackedSystemdUnit(serverID: serverID, unitName: $0)
            })
        }
        return trackedSystemdUnits.filter { $0.serverID == serverID }.map(\.unitName)
    }

    func addSystemdUnits(_ names: [String], for serverID: UUID) {
        let existing = Set(trackedSystemdUnits.filter { $0.serverID == serverID }.map(\.unitName))
        for name in names where !existing.contains(name) {
            trackedSystemdUnits.append(TrackedSystemdUnit(serverID: serverID, unitName: name))
        }
    }

    func removeSystemdUnit(_ name: String, for serverID: UUID) {
        trackedSystemdUnits.removeAll { $0.serverID == serverID && $0.unitName == name }
    }

    func server(_ id: UUID?) -> Server? { servers.first { $0.id == id } }

    func exportTransferPayload(for serverIDs: Set<UUID>) throws -> Data {
        let tunnelIDs = Set(tunnels.filter { serverIDs.contains($0.serverID) }.map(\.id))
        let payload = ServerTransferPayload(
            projects: projects.filter { serverIDs.contains($0.serverID) },
            pm2Configs: pm2Configs.filter { serverIDs.contains($0.serverID) },
            tunnels: tunnels.filter { serverIDs.contains($0.serverID) },
            routes: routes.filter { tunnelIDs.contains($0.tunnelID) },
            trackedSystemdUnits: trackedSystemdUnits.filter { serverIDs.contains($0.serverID) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }

    func importTransferPayload(_ data: Data, serverIDMapping: [UUID: UUID]) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(ServerTransferPayload.self, from: data)

        var projectIDs: [UUID: UUID] = [:]
        let copiedProjects = try payload.projects.map { original -> Project in
            guard let serverID = serverIDMapping[original.serverID] else {
                throw NSError(domain: "AppStore", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "A project refers to a source server that is not part of the transfer."
                ])
            }
            var copy = original
            let newID = UUID()
            projectIDs[original.id] = newID
            copy.id = newID
            copy.serverID = serverID
            return copy
        }

        var tunnelIDs: [UUID: UUID] = [:]
        let copiedTunnels = try payload.tunnels.map { original -> CloudflareTunnel in
            guard let serverID = serverIDMapping[original.serverID] else {
                throw NSError(domain: "AppStore", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "A tunnel refers to a source server that is not part of the transfer."
                ])
            }
            var copy = original
            let newID = UUID()
            tunnelIDs[original.id] = newID
            copy.id = newID
            copy.serverID = serverID
            return copy
        }

        let copiedPM2 = try payload.pm2Configs.map { original -> PM2AppConfig in
            guard let serverID = serverIDMapping[original.serverID] else {
                throw NSError(domain: "AppStore", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "A PM2 app refers to a source server that is not part of the transfer."
                ])
            }
            var copy = original
            copy.id = UUID()
            copy.serverID = serverID
            if let oldProjectID = original.projectID {
                copy.projectID = projectIDs[oldProjectID]
            }
            return copy
        }
        let copiedRoutes = payload.routes.compactMap { original -> TunnelRoute? in
            guard let newTunnelID = tunnelIDs[original.tunnelID] else { return nil }
            var copy = original
            copy.id = UUID()
            copy.tunnelID = newTunnelID
            return copy
        }
        let copiedUnits = try payload.trackedSystemdUnits.map { original -> TrackedSystemdUnit in
            guard let serverID = serverIDMapping[original.serverID] else {
                throw NSError(domain: "AppStore", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "A tracked systemd unit refers to a source server that is not part of the transfer."
                ])
            }
            var copy = original
            copy.id = UUID()
            copy.serverID = serverID
            return copy
        }

        projects.append(contentsOf: copiedProjects)
        pm2Configs.append(contentsOf: copiedPM2)
        tunnels.append(contentsOf: copiedTunnels)
        routes.append(contentsOf: copiedRoutes)
        trackedSystemdUnits.append(contentsOf: copiedUnits)
    }

    func removeData(for serverIDs: Set<UUID>) {
        let removedTunnelIDs = Set(tunnels.filter { serverIDs.contains($0.serverID) }.map(\.id))
        projects.removeAll { serverIDs.contains($0.serverID) }
        pm2Configs.removeAll { serverIDs.contains($0.serverID) }
        tunnels.removeAll { serverIDs.contains($0.serverID) }
        routes.removeAll { removedTunnelIDs.contains($0.tunnelID) }
        trackedSystemdUnits.removeAll { serverIDs.contains($0.serverID) }
    }

    // MARK: - Backup / Restore

    /// Bundles everything into one portable JSON blob, e.g. before a macOS reinstall
    /// or moving to a new Mac.
    ///
    /// PM2 env vars are deliberately EXCLUDED — they live only in this Mac's
    /// Keychain, not in this file, so a backup file can't leak secrets if it ends
    /// up somewhere it shouldn't (cloud storage, a shared drive, etc). After
    /// importing on a new Mac, PM2 apps will need their env vars re-entered once.
    func exportBackupData() -> Data? {
        let backup = AppBackup(
            servers: servers,
            projects: projects,
            pm2Configs: pm2Configs.map { cfg in var c = cfg; c.env = [:]; return c },
            tunnels: tunnels,
            routes: routes,
            trackedSystemdUnits: trackedSystemdUnits
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return try? enc.encode(backup)
    }

    /// Replaces everything currently in the app with the contents of a backup.
    @discardableResult
    func importBackupData(_ data: Data) -> Bool {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let backup = try? dec.decode(AppBackup.self, from: data) else { return false }
        servers = backup.servers
        projects = backup.projects
        pm2Configs = backup.pm2Configs // env comes back empty; Keychain didn't travel with the file, by design
        tunnels = backup.tunnels
        routes = backup.routes
        trackedSystemdUnits = backup.trackedSystemdUnits
        selectedServerID = servers.first?.id
        return true
    }
}

/// A single portable snapshot of everything the app remembers (minus PM2 env vars —
/// see exportBackupData()).
struct AppBackup: Codable {
    var servers: [Server]
    var projects: [Project]
    var pm2Configs: [PM2AppConfig]
    var tunnels: [CloudflareTunnel]
    var routes: [TunnelRoute]
    var trackedSystemdUnits: [TrackedSystemdUnit]
}

struct ServerTransferPayload: Codable {
    var projects: [Project]
    var pm2Configs: [PM2AppConfig]
    var tunnels: [CloudflareTunnel]
    var routes: [TunnelRoute]
    var trackedSystemdUnits: [TrackedSystemdUnit]
}