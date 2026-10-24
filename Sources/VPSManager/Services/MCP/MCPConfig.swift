import Foundation

/// How much an AI agent connected over MCP may do on one server.
enum AgentAccess: String, Codable, CaseIterable, Identifiable {
    /// Not visible to agents at all.
    case off
    /// Status, logs, file reads, listings — nothing that changes the server.
    case readOnly
    /// Everything read-only allows, plus running commands, writing files and
    /// starting/stopping services, containers and PM2 apps.
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .readOnly: return "Read-only"
        case .full: return "Full access"
        }
    }
}

/// MCP settings, shared between the app (which edits them in Settings ▸ AI
/// Agents) and the `--mcp` server process (which reads them on every tool call).
/// Kept as a JSON file next to servers.json rather than in UserDefaults, because
/// the MCP process may run as a bare binary with a different defaults domain.
struct MCPConfig: Codable, Equatable {
    var enabled = false
    /// Keyed by server id (uuidString). Servers not listed are `.off`.
    var access: [String: AgentAccess] = [:]

    static let fileName = "mcp.json"

    static func load() -> MCPConfig {
        DiskStore.shared.load(fileName, as: MCPConfig.self, default: MCPConfig())
    }

    func save() {
        DiskStore.shared.save(self, to: Self.fileName)
    }

    func access(for serverID: UUID) -> AgentAccess {
        access[serverID.uuidString] ?? .off
    }

    mutating func setAccess(_ level: AgentAccess, for serverID: UUID) {
        access[serverID.uuidString] = level == .off ? nil : level
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        access = try c.decodeIfPresent([String: AgentAccess].self, forKey: .access) ?? [:]
    }
}

/// One tool call made by an agent, appended to mcp-activity.jsonl so the app
/// can show exactly what agents did and when.
struct MCPActivity: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var tool: String
    var server: String?
    var summary: String
    var outcome: Outcome

    enum Outcome: String, Codable {
        case ok, failed, denied
    }

    static let fileName = "mcp-activity.jsonl"
    private static let maxEntries = 500

    private static var url: URL { DiskStore.shared.url(fileName) }

    static func append(_ entry: MCPActivity) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(entry) else { return }
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
        trimIfNeeded()
    }

    /// Newest first.
    static func recent(limit: Int = 200) -> [MCPActivity] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").suffix(limit).reversed().compactMap {
            try? decoder.decode(MCPActivity.self, from: Data($0.utf8))
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func trimIfNeeded() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n")
        guard lines.count > maxEntries * 2 else { return }
        let kept = lines.suffix(maxEntries).joined(separator: "\n") + "\n"
        try? kept.write(to: url, atomically: true, encoding: .utf8)
    }
}
