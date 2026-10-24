import Foundation
import Combine

/// Keeps an up-to-date copy of the app's settings (the same file as Settings ▸
/// Backup ▸ Export) in a folder of the user's choosing — iCloud Drive by
/// default, so it follows them to a new Mac — written a few seconds after
/// anything changes. In "git" mode the folder is a git repository instead: one
/// file, committed (and pushed, if a remote is set) on every change, so history
/// lives in git rather than in timestamped copies.
///
/// PM2 environment variables are never included (see AppStore.exportBackupData).
@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()

    static let enabledKey = "autoBackupEnabled"
    static let folderKey = "autoBackupFolder"
    static let gitKey = "autoBackupUseGit"
    static let keepCount = 30

    @Published private(set) var lastBackupAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isRunning = false

    private weak var store: AppStore?
    private var cancellable: AnyCancellable?

    static var defaultFolder: String {
        let iCloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if FileManager.default.fileExists(atPath: iCloud.path) {
            return iCloud.appendingPathComponent("VPS Manager Backups").path
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/VPS Manager Backups").path
    }

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var usesGit: Bool { UserDefaults.standard.bool(forKey: Self.gitKey) }
    var folder: String { UserDefaults.standard.string(forKey: Self.folderKey) ?? Self.defaultFolder }

    func attach(store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        let changes: [AnyPublisher<Void, Never>] = [
            store.$servers.map { _ in () }.eraseToAnyPublisher(),
            store.$projects.map { _ in () }.eraseToAnyPublisher(),
            store.$pm2Configs.map { _ in () }.eraseToAnyPublisher(),
            store.$tunnels.map { _ in () }.eraseToAnyPublisher(),
            store.$routes.map { _ in () }.eraseToAnyPublisher(),
            store.$trackedSystemdUnits.map { _ in () }.eraseToAnyPublisher(),
        ]
        cancellable = Publishers.MergeMany(changes)
            .dropFirst(changes.count)   // each @Published replays its current value on subscribe
            .debounce(for: .seconds(5), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self, self.isEnabled else { return }
                Task { await self.backUpNow() }
            }
    }

    func backUpNow() async {
        guard let store, let data = store.exportBackupData(), !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let folderURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            if usesGit {
                try data.write(to: folderURL.appendingPathComponent("vpsmanager-backup.json"), options: .atomic)
                try await commit(in: folderURL)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
                try data.write(to: folderURL.appendingPathComponent("vpsmanager-latest.json"), options: .atomic)
                try data.write(to: folderURL.appendingPathComponent("vpsmanager-\(formatter.string(from: Date())).json"), options: .atomic)
                prune(folderURL)
            }
            lastBackupAt = Date()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Keeps the newest `keepCount` timestamped copies.
    private func prune(_ folder: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let stamped = files.filter { $0.hasPrefix("vpsmanager-20") && $0.hasSuffix(".json") }.sorted()
        for name in stamped.dropLast(Self.keepCount) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func commit(in folder: URL) async throws {
        let shell = ShellService.shared
        let path = folder.path
        if !FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path) {
            let r = try await shell.run("git", ["-C", path, "init"])
            guard r.success else { throw gitError("git init", r) }
        }
        _ = try await shell.run("git", ["-C", path, "add", "vpsmanager-backup.json"])
        let status = try await shell.run("git", ["-C", path, "status", "--porcelain", "vpsmanager-backup.json"])
        guard !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }   // nothing changed
        let commit = try await shell.run("git", ["-C", path,
                                                 "-c", "user.name=VPS Manager", "-c", "user.email=vpsmanager@localhost",
                                                 "commit", "-m", "Backup \(Date().formatted(.iso8601))"])
        guard commit.success else { throw gitError("git commit", commit) }
        let remotes = try await shell.run("git", ["-C", path, "remote"])
        if let remote = remotes.stdout.split(separator: "\n").first.map(String.init) {
            // Never block on a credential prompt nobody can see.
            let push = try await shell.run("env", ["GIT_TERMINAL_PROMPT=0", "git", "-C", path, "push", "-u", remote, "HEAD"], timeout: 60)
            guard push.success else { throw gitError("git push", push) }
        }
    }

    private func gitError(_ step: String, _ result: ShellResult) -> NSError {
        let detail = [result.stderr, result.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "exit code \(result.exitCode)"
        return NSError(domain: "BackupManager", code: Int(result.exitCode), userInfo: [NSLocalizedDescriptionKey: "\(step) failed: \(detail)"])
    }
}
