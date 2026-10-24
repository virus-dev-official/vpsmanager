import Foundation

struct RemoteFile: Identifiable, Hashable {
    var id: String { path }
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int64
    let permissions: String
    var isSymlink: Bool = false
    var modifiedAt: Date? = nil
}

final class SFTPService {
    static let shared = SFTPService()

    /// Lists a remote directory with GNU `find -printf`, NUL-separated: unlike
    /// parsing `ls -la`, this survives any filename (runs of spaces, " -> " in
    /// names) and reports what a symlink points at, so linked folders open as
    /// folders. Falls back to `ls` on systems without GNU find (BusyBox, BSD).
    func list(_ server: Server, path: String) async throws -> [RemoteFile] {
        let findCmd = "find -H '\(escaped(path))' -mindepth 1 -maxdepth 1 -printf '%y\\t%Y\\t%s\\t%M\\t%T@\\t%f\\0'"
        let result = try await ShellService.shared.ssh(server, command: findCmd)
        let records = result.stdout.split(separator: "\0").map(String.init)
        if records.isEmpty && !result.success {
            if result.stderr.localizedCaseInsensitiveContains("printf") || result.exitCode == 127 {
                return try await listWithLs(server, path: path)
            }
            throw SSHCommandFailure(command: findCmd, result: result, sshUser: server.user)
        }

        var files: [RemoteFile] = []
        for record in records {
            let fields = record.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, !fields[5].isEmpty else { continue }
            let name = fields[5].trimmingCharacters(in: .newlines)
            files.append(RemoteFile(
                name: name,
                path: SFTPService.joinPath(path, name),
                isDirectory: fields[1] == "d",
                sizeBytes: Int64(fields[2]) ?? 0,
                permissions: fields[3],
                isSymlink: fields[0] == "l",
                modifiedAt: Double(fields[4]).map { Date(timeIntervalSince1970: $0) }
            ))
        }
        return Self.sorted(files)
    }

    private func listWithLs(_ server: Server, path: String) async throws -> [RemoteFile] {
        let cmd = "ls -laL '\(escaped(path))' 2>/dev/null"
        let output = try await ShellService.shared.sshExpectingSuccess(server, command: cmd)
        var files: [RemoteFile] = []
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 9 else { continue }
            let perms = parts[0]
            guard perms.first == "d" || perms.first == "-" else { continue }
            let name = parts[8]
            if name == "." || name == ".." { continue }
            files.append(RemoteFile(name: name, path: SFTPService.joinPath(path, name), isDirectory: perms.first == "d",
                                    sizeBytes: Int64(parts[4]) ?? 0, permissions: perms))
        }
        return Self.sorted(files)
    }

    private static func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Reads a remote text file's contents via base64 over ssh (safe for any content/encoding).
    func readFile(_ server: Server, path: String, timeout: TimeInterval = 60) async throws -> String {
        let data = try await readFileData(server, path: path, timeout: timeout)
        return String(data: data, encoding: .utf8) ?? "<binary file — cannot display>"
    }

    /// Reads a remote file's raw bytes via base64 over ssh. Safe for binary content
    /// such as images, audio, video, PDFs, or any other non-text file.
    func readFileData(_ server: Server, path: String, timeout: TimeInterval = 60) async throws -> Data {
        let cmd = "base64 -w0 '\(escaped(path))' 2>/dev/null || base64 '\(escaped(path))'"
        let b64 = try await ShellService.shared.sshExpectingSuccess(server, command: cmd, timeout: timeout)
        guard let data = Data(base64Encoded: b64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NSError(domain: "SFTPService", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not decode file contents"])
        }
        return data
    }

    /// Writes text content to a remote file by piping base64-decoded stdin over ssh.
    func writeFile(_ server: Server, path: String, contents: String, timeout: TimeInterval = 120) async throws {
        guard let data = contents.data(using: .utf8) else { return }
        try await writeFileData(server, path: path, data: data, timeout: timeout)
    }

    /// Writes raw bytes to a remote file by piping base64-decoded stdin over ssh.
    /// Safe for binary content — used for both uploads and any in-app binary writes.
    func writeFileData(_ server: Server, path: String, data: Data, timeout: TimeInterval = 120) async throws {
        let b64 = data.base64EncodedString()
        let cmd = "base64 -d > '\(escaped(path))'"
        let r = try await ShellService.shared.run("ssh", server.sshArgs + [cmd], input: b64, timeout: timeout)
        guard r.success else {
            throw NSError(domain: "SFTPService", code: 3, userInfo: [NSLocalizedDescriptionKey: r.stderr.isEmpty ? "Write failed" : r.stderr])
        }
    }

    func createDirectory(_ server: Server, path: String) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "mkdir -p '\(escaped(path))'")
    }

    func createFile(_ server: Server, path: String) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "touch '\(escaped(path))'")
    }

    func delete(_ server: Server, path: String, isDirectory: Bool) async throws {
        let flag = isDirectory ? "-rf" : "-f"
        try await ShellService.shared.sshExpectingSuccess(server, command: "rm \(flag) '\(escaped(path))'")
    }

    func rename(_ server: Server, from: String, to: String) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "mv '\(escaped(from))' '\(escaped(to))'")
    }

    // MARK: - Downloads

    /// Downloads a remote file (or a whole folder, recursively) with `scp`, which
    /// streams straight to disk over the shared SSH connection — no loading the
    /// file into memory or base64-inflating it the way `readFileData` does.
    func downloadFile(_ server: Server, remotePath: String, to localURL: URL, timeout: TimeInterval = 3600) async throws {
        try await scp(server, ["-r", "\(server.sshTarget):\(remotePath)", localURL.path], timeout: timeout)
    }

    // MARK: - Uploads

    /// Uploads a single local file into a remote directory, keeping its filename.
    func uploadFile(_ server: Server, localURL: URL, remoteDir: String, timeout: TimeInterval = 3600) async throws {
        try await uploadItem(server, localURL: localURL, remoteDir: remoteDir, timeout: timeout)
    }

    /// Uploads a local file OR folder into a remote directory (folders recursively,
    /// mirroring their structure). This is what backs drag-and-drop uploads from
    /// Finder, so it transparently supports dropping a mix of files and folders.
    func uploadItem(_ server: Server, localURL: URL, remoteDir: String, timeout: TimeInterval = 3600) async throws {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            throw NSError(domain: "SFTPService", code: 4, userInfo: [NSLocalizedDescriptionKey: "\(localURL.lastPathComponent) no longer exists"])
        }
        let destination = SFTPService.joinPath(remoteDir, localURL.lastPathComponent)
        try await scp(server, ["-r", localURL.path, "\(server.sshTarget):\(destination)"], timeout: timeout)
    }

    /// Modern OpenSSH scp speaks the SFTP protocol, so remote paths are taken
    /// literally (no remote shell globbing or quoting needed).
    private func scp(_ server: Server, _ arguments: [String], timeout: TimeInterval) async throws {
        let result = try await ShellService.shared.run("scp", ["-q"] + server.scpArgs + arguments, timeout: timeout)
        guard result.success else {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "SFTPService", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: message.isEmpty ? "Transfer failed (scp exit code \(result.exitCode))." : message
            ])
        }
    }

    // MARK: - Archives

    /// Extracts a remote archive in place, next to itself. Covers the formats you'll
    /// actually run into on a VPS: zip, tar, and tar's gzip/bzip2/xz variants.
    func extractArchive(_ server: Server, path: String, timeout: TimeInterval = 300) async throws {
        let dir = (path as NSString).deletingLastPathComponent
        let name = ((path as NSString).lastPathComponent).lowercased()
        let ext = (name as NSString).pathExtension

        let cmd: String
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tgz") {
            cmd = "tar -xzf '\(escaped(path))' -C '\(escaped(dir))'"
        } else if name.hasSuffix(".tar.bz2") || name.hasSuffix(".tbz2") {
            cmd = "tar -xjf '\(escaped(path))' -C '\(escaped(dir))'"
        } else if name.hasSuffix(".tar.xz") {
            cmd = "tar -xJf '\(escaped(path))' -C '\(escaped(dir))'"
        } else if ext == "tar" {
            cmd = "tar -xf '\(escaped(path))' -C '\(escaped(dir))'"
        } else if ext == "zip" {
            cmd = "unzip -o '\(escaped(path))' -d '\(escaped(dir))'"
        } else if ext == "gz" {
            cmd = "gunzip -k '\(escaped(path))'"
        } else if ext == "bz2" {
            cmd = "bunzip2 -k '\(escaped(path))'"
        } else {
            throw NSError(domain: "SFTPService", code: 5, userInfo: [NSLocalizedDescriptionKey: "Don't know how to extract this file type."])
        }

        try await ShellService.shared.sshExpectingSuccess(server, command: cmd, timeout: timeout)
    }

    // MARK: - Helpers

    static func joinPath(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    private func escaped(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}