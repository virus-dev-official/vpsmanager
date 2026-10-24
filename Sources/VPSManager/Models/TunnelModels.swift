import Foundation

struct CloudflareTunnel: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var serverID: UUID
    var tunnelName: String
    var tunnelID: String = ""          // filled in after `cloudflared tunnel create` returns it
    var credentialsFile: String = ""   // /root/.cloudflared/<id>.json or under the admin user's home
    var configPath: String = "/etc/cloudflared/config.yml"
    var systemdUnit: String = "cloudflared"  // the actual unit that runs this tunnel, e.g. "cloudflared-my-app"
    var createdAt: Date = Date()

    init(id: UUID = UUID(), serverID: UUID, tunnelName: String, tunnelID: String = "", credentialsFile: String = "", configPath: String = "/etc/cloudflared/config.yml", systemdUnit: String = "cloudflared", createdAt: Date = Date()) {
        self.id = id
        self.serverID = serverID
        self.tunnelName = tunnelName
        self.tunnelID = tunnelID
        self.credentialsFile = credentialsFile
        self.configPath = configPath
        self.systemdUnit = systemdUnit
        self.createdAt = createdAt
    }

    // Manual decoding so a field added after some users already have data saved to
    // disk (systemdUnit) doesn't throw a keyNotFound error on old files — that would
    // silently wipe out already-saved tunnels the same way the earlier date-decoding
    // bug did. Any newly-added field going forward should follow this same pattern.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        serverID = try c.decode(UUID.self, forKey: .serverID)
        tunnelName = try c.decode(String.self, forKey: .tunnelName)
        tunnelID = try c.decodeIfPresent(String.self, forKey: .tunnelID) ?? ""
        credentialsFile = try c.decodeIfPresent(String.self, forKey: .credentialsFile) ?? ""
        configPath = try c.decodeIfPresent(String.self, forKey: .configPath) ?? "/etc/cloudflared/config.yml"
        systemdUnit = try c.decodeIfPresent(String.self, forKey: .systemdUnit) ?? "cloudflared"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct TunnelRoute: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var tunnelID: UUID   // local CloudflareTunnel.id
    var hostname: String // e.g. api.example.com
    var localPort: Int
    var service: String { "http://localhost:\(localPort)" }
}

struct SystemdUnitStatus: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var activeState: String   // active, inactive, failed
    var subState: String      // running, dead, exited
    var enabled: Bool
}

/// Which systemd units the user wants tracked/shown for a given server. Kept as its
/// own persisted list rather than a hardcoded default, so custom services (echo-api,
/// echo-scheduler, etc.) survive tab switches and app relaunches once added.
struct TrackedSystemdUnit: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var serverID: UUID
    var unitName: String
}