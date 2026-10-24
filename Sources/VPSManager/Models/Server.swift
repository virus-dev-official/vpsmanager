import Foundation
import SwiftUI
import CryptoKit

struct Server: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var nickname: String
    var host: String
    var port: Int = 22
    var user: String
    /// Path to the private key used for passwordless auth, e.g. ~/.ssh/id_ed25519
    var identityFile: String
    var colorTag: ServerColorTag = .blue
    var createdAt: Date = Date()
    var lastConnectedAt: Date? = nil

    /// Whether the initial hardening wizard (disable root, own user, key-only auth) has completed.
    var isHardened: Bool = false

    var sshTarget: String { "\(user)@\(host)" }

    var hostGroupKey: String {
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return "\(normalizedHost):\(port)"
    }

    /// Deterministic path for this server's SSH multiplexing control socket.
    /// Computed ourselves (rather than relying on ssh's own %C token) so the app can
    /// find and delete it directly if a connection goes stale — e.g. after the Mac
    /// sleeps/wakes or WiFi drops briefly, the underlying connection can die while
    /// this socket file lingers for the full ControlPersist duration, silently
    /// failing every command in the meantime unless something cleans it up.
    ///
    /// Lives in a private (0700) directory under ~/.ssh rather than world-writable
    /// /tmp, where another local user could pre-create or squat on a predictable
    /// name. Hashed to keep the full path well under the 104-byte socket limit.
    var controlSocketPath: String {
        let digest = SHA256.hash(data: Data("\(user)@\(host):\(port)".utf8))
        let name = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return Server.controlSocketDirectory + "/" + name
    }

    static let controlSocketDirectory: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/vpsmgr").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir)
        return dir
    }()

    /// Connection options shared by ssh, scp and rsync's `-e ssh …`: everything
    /// in `sshArgs` except the port flag (spelled differently per tool) and the
    /// destination.
    var sshOptions: [String] {
        var args: [String] = []
        if !identityFile.isEmpty {
            args += ["-i", (identityFile as NSString).expandingTildeInPath]
        }
        args += [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8",
            "-o", "ControlMaster=auto",
            "-o", "ControlPersist=10m",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
        ]
        return args
    }

    /// Arguments for `scp` (note the capital -P for port).
    var scpArgs: [String] { ["-P", "\(port)"] + sshOptions }

    var sshArgs: [String] {
        // Reuse one authenticated connection across requests instead of paying a
        // fresh TCP+auth handshake for every single command. ServerAlive* makes
        // the master itself notice a dead connection and exit on its own rather
        // than lingering as a zombie; ShellService additionally detects and
        // clears a stale socket file and retries once if a command still fails.
        ["-p", "\(port)"] + sshOptions + [sshTarget]
    }
}

struct ServerGroup: Identifiable, Hashable {
    let id: String
    let host: String
    let port: Int
    let servers: [Server]

    var title: String {
        port == 22 ? host : "\(host):\(port)"
    }
}

enum ServerColorTag: String, Codable, CaseIterable {
    case blue, purple, green, orange, red, gray

    var swiftUIColor: String { rawValue } // resolved in View layer

    var color: Color {
        switch self {
        // `.blue` is every server's default tag (and the raw value is shared
        // with servers.json), so it renders in the ember brand color rather
        // than literal blue.
        case .blue: return Color(hex: 0xE8501F)
        case .purple: return .purple
        case .green: return .green
        case .orange: return .orange
        case .red: return .red
        case .gray: return .gray
        }
    }
}