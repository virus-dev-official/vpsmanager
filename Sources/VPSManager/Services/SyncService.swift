import Foundation

final class SyncService {
    static let shared = SyncService()

    /// Checks whether the remote path exists on the server.
    func remoteFolderExists(_ server: Server, remotePath: String) async throws -> Bool {
        let r = try await ShellService.shared.ssh(server, command: "test -d \(shellQuote(remotePath)) && echo YES || echo NO")
        return r.stdout.contains("YES")
    }

    func createRemoteFolder(_ server: Server, remotePath: String) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "mkdir -p \(shellQuote(remotePath))")
    }

    private func writeExcludeFile(_ project: Project) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vpsmgr-exclude-\(UUID().uuidString).txt")
        try project.excludeFileContents.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    private func rsyncBaseArgs(_ server: Server, project: Project, excludeFile: URL, deleteRemoved: Bool = true) -> [String] {
        var localPath = (project.localPath as NSString).expandingTildeInPath
        if !localPath.hasSuffix("/") { localPath += "/" }
        var remotePath = project.remotePath
        if !remotePath.hasSuffix("/") { remotePath += "/" }

        let sshArgs = ["ssh", "-p", "\(server.port)"] + server.sshOptions
        let sshCmd = sshArgs.map(shellQuote).joined(separator: " ")

        return [
            "-avz"] + (deleteRemoved ? ["--delete"] : []) + [
            "--exclude-from=\(excludeFile.path)",
            "-e", sshCmd,
            localPath,
            "\(server.sshTarget):\(remotePath)"
        ]
    }

    /// Runs `rsync --dry-run --itemize-changes` and parses output into a change list for preview.
    func previewChanges(server: Server, project: Project) async throws -> [SyncChange] {
        let excludeFile = try writeExcludeFile(project)
        defer { try? FileManager.default.removeItem(at: excludeFile) }
        var args = ["--dry-run", "-i"] + rsyncBaseArgs(server, project: project, excludeFile: excludeFile)
        // -i (itemize-changes) already implies -v info; keep it lean.
        args.removeAll { $0 == "-avz" }
        args.insert("-avz", at: 2)

        let result = try await ShellService.shared.run("rsync", args)
        guard result.success else {
            throw commandFailure(result, operation: "Sync preview")
        }
        return parseItemizedOutput(result.stdout)
    }

    /// Performs the actual push. `deleteRemoved` mirrors local deletions to the
    /// server (`--delete`); the reviewed manual push uses it, unattended auto-sync
    /// only does when the project explicitly opts in.
    func push(server: Server, project: Project, deleteRemoved: Bool = true, progress: ((String) -> Void)? = nil) async throws {
        let excludeFile = try writeExcludeFile(project)
        defer { try? FileManager.default.removeItem(at: excludeFile) }
        let args = rsyncBaseArgs(server, project: project, excludeFile: excludeFile, deleteRemoved: deleteRemoved)
        let result = try await ShellService.shared.run("rsync", args, timeout: 3600)
        let output = [result.stdout, result.stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        progress?(output.isEmpty ? "rsync exited with code \(result.exitCode).\n" : output + "\n")
        guard result.success else {
            throw commandFailure(result, operation: "Initial sync")
        }
    }

    private func commandFailure(_ result: ShellResult, operation: String) -> NSError {
        let details = [result.stderr, result.stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "No output was returned by rsync."
        return NSError(
            domain: "SyncService",
            code: Int(result.exitCode),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed (exit code \(result.exitCode)): \(details)"]
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func parseItemizedOutput(_ output: String) -> [SyncChange] {
        // rsync -i lines look like: ">f+++++++++ path/to/file" (new), ">f.st...... path" (updated), "*deleting   path".
        // The flag field is 11 characters in rsync 3 but 9 in the openrsync/rsync 2.6 that
        // ships with macOS, so split on the first space rather than at a fixed column.
        var changes: [SyncChange] = []
        for line in output.split(separator: "\n") {
            let str = String(line)
            guard let space = str.firstIndex(of: " ") else { continue }
            let flags = str[..<space]
            let path = str[space...].trimmingCharacters(in: .whitespaces)
            if str.hasPrefix("*deleting") {
                changes.append(SyncChange(path: path, kind: .delete))
            } else if str.hasPrefix(">f") || str.hasPrefix("<f") {
                let kind: SyncChange.Kind = flags.dropFirst(2).allSatisfy { $0 == "+" } ? .create : .update
                changes.append(SyncChange(path: path, kind: kind))
            } else if str.hasPrefix("cd") {
                if !path.isEmpty { changes.append(SyncChange(path: path, kind: .createDir)) }
            }
        }
        return changes
    }

    /// Checks whether any of the given (remote-relative) paths were modified on the
    /// server after `since`. Since sync is push-only (local → VPS), a file edited
    /// directly on the server — through the in-app file editor, or by hand — after
    /// the last push would otherwise get silently clobbered the next time you push,
    /// with no indication anything was lost. This lets the diff view warn first.
    func remoteModifiedSince(server: Server, project: Project, paths: [String], since: Date) async -> Set<String> {
        guard !paths.isEmpty else { return [] }
        var remotePath = project.remotePath
        if !remotePath.hasSuffix("/") { remotePath += "/" }
        let escapedPaths = paths.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: " ")
        let cmd = """
        cd "\(remotePath)" 2>/dev/null || exit 0
        for f in \(escapedPaths); do
          if [ -e "$f" ]; then
            mtime=$(stat -c '%Y' "$f" 2>/dev/null || stat -f '%m' "$f" 2>/dev/null)
            echo "$mtime|$f"
          fi
        done
        """
        guard let output = try? await ShellService.shared.ssh(server, command: cmd, timeout: 15) else { return [] }
        let threshold = since.timeIntervalSince1970
        var modified: Set<String> = []
        for line in output.stdout.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let mtime = Double(parts[0]) else { continue }
            if mtime > threshold {
                modified.insert(String(parts[1]))
            }
        }
        return modified
    }
}