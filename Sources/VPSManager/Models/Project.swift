import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var serverID: UUID
    var name: String
    var localPath: String
    var remotePath: String
    /// gitignore-style patterns, one per line, written to an exclude file passed to rsync
    var excludePatterns: [String] = [".git/", ".env", "node_modules/", "__pycache__/", ".DS_Store", "venv/", ".venv/"]
    var lastSyncedAt: Date? = nil
    var autoSyncOnSave: Bool = false
    /// Whether unattended auto-sync may delete files on the server that were
    /// deleted locally (rsync --delete). Off by default: with nobody reviewing a
    /// diff, a wrong local path would otherwise wipe the remote folder.
    var autoSyncDeletes: Bool = false

    init(id: UUID = UUID(), serverID: UUID, name: String, localPath: String, remotePath: String,
         excludePatterns: [String] = [".git/", ".env", "node_modules/", "__pycache__/", ".DS_Store", "venv/", ".venv/"],
         lastSyncedAt: Date? = nil, autoSyncOnSave: Bool = false, autoSyncDeletes: Bool = false) {
        self.id = id
        self.serverID = serverID
        self.name = name
        self.localPath = localPath
        self.remotePath = remotePath
        self.excludePatterns = excludePatterns
        self.lastSyncedAt = lastSyncedAt
        self.autoSyncOnSave = autoSyncOnSave
        self.autoSyncDeletes = autoSyncDeletes
    }

    /// Tolerates fields added in later versions being absent from older
    /// projects.json files (synthesized Codable would reject the whole file).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        serverID = try c.decode(UUID.self, forKey: .serverID)
        name = try c.decode(String.self, forKey: .name)
        localPath = try c.decode(String.self, forKey: .localPath)
        remotePath = try c.decode(String.self, forKey: .remotePath)
        excludePatterns = try c.decodeIfPresent([String].self, forKey: .excludePatterns) ?? []
        lastSyncedAt = try c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        autoSyncOnSave = try c.decodeIfPresent(Bool.self, forKey: .autoSyncOnSave) ?? false
        autoSyncDeletes = try c.decodeIfPresent(Bool.self, forKey: .autoSyncDeletes) ?? false
    }

    var excludeFileContents: String {
        excludePatterns.joined(separator: "\n") + "\n"
    }
}

struct SyncChange: Identifiable, Hashable {
    enum Kind: String { case create, update, delete, createDir }
    let id = UUID()
    let path: String
    let kind: Kind
}
