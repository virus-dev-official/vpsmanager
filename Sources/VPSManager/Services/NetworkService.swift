import Foundation

struct ListeningPort: Identifiable, Hashable {
    var id: String { "\(proto)-\(address)-\(port)" }
    let proto: String        // tcp / udp
    let address: String      // bind address, e.g. 0.0.0.0, 127.0.0.1, [::]
    let port: Int
    let process: String?     // needs sudo to be known for other users' processes

    /// Bound only to loopback, so unreachable from outside the server.
    var isLocalOnly: Bool {
        address.hasPrefix("127.") || address == "[::1]" || address == "::1" || address.contains("%lo")
    }
}

struct FirewallRule: Identifiable, Hashable {
    var id: Int { number }
    let number: Int
    let target: String       // "22/tcp", "OpenSSH", "80 (v6)"
    let action: String       // ALLOW IN, DENY, LIMIT …
    let from: String
}

struct FirewallStatus {
    var installed = true
    var active = false
    var rules: [FirewallRule] = []
}

/// Listening sockets (`ss`) and the ufw firewall. Everything that changes the
/// firewall needs passwordless sudo, same as the systemd actions.
final class NetworkService {
    static let shared = NetworkService()

    func listeningPorts(_ server: Server) async throws -> [ListeningPort] {
        // With sudo, ss can name every process; without it only the user's own.
        let cmd = "sudo -n ss -tulpnH 2>/dev/null || ss -tulpnH 2>/dev/null || ss -tulnH"
        let output = try await ShellService.shared.sshExpectingSuccess(server, command: cmd)
        var seen = Set<String>()
        var ports: [ListeningPort] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count >= 5, let colon = fields[4].lastIndex(of: ":") else { continue }
            let local = fields[4]
            guard let port = Int(local[local.index(after: colon)...]) else { continue }
            let address = String(local[..<colon])
            var process: String?
            if let users = fields.dropFirst(6).first(where: { $0.hasPrefix("users:") }),
               let start = users.range(of: "((\""),
               let end = users[start.upperBound...].firstIndex(of: "\"") {
                process = String(users[start.upperBound..<end])
            }
            let entry = ListeningPort(proto: fields[0], address: address, port: port, process: process)
            if seen.insert(entry.id).inserted { ports.append(entry) }
        }
        return ports.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    func firewall(_ server: Server) async throws -> FirewallStatus {
        let cmd = "command -v ufw >/dev/null 2>&1 || { echo __NO_UFW__; exit 0; }; sudo -n ufw status numbered"
        let result = try await ShellService.shared.ssh(server, command: cmd)
        if result.stdout.contains("__NO_UFW__") { return FirewallStatus(installed: false) }
        guard result.success else {
            throw SSHCommandFailure(command: cmd, result: result, sshUser: server.user)
        }
        var status = FirewallStatus()
        status.active = result.stdout.contains("Status: active")
        let pattern = try NSRegularExpression(pattern: #"^\[\s*(\d+)\]\s+(.+?)\s{2,}((?:ALLOW|DENY|REJECT|LIMIT)(?: (?:IN|OUT|FWD))?)\s+(.+?)\s*$"#)
        for line in result.stdout.split(separator: "\n").map(String.init) {
            let range = NSRange(line.startIndex..., in: line)
            guard let m = pattern.firstMatch(in: line, range: range), m.numberOfRanges == 5,
                  let n = Range(m.range(at: 1), in: line), let t = Range(m.range(at: 2), in: line),
                  let a = Range(m.range(at: 3), in: line), let f = Range(m.range(at: 4), in: line),
                  let number = Int(line[n]) else { continue }
            status.rules.append(FirewallRule(number: number, target: String(line[t]), action: String(line[a]), from: String(line[f])))
        }
        return status
    }

    enum RuleAction: String, CaseIterable, Identifiable {
        case allow, deny, limit
        var id: String { rawValue }
    }

    /// `port` is a number, range ("8000:8100") or app profile name ("OpenSSH").
    func addRule(_ server: Server, action: RuleAction, port: String, proto: String?, from: String?) async throws {
        var cmd = "sudo -n ufw \(action.rawValue)"
        if let from, !from.isEmpty {
            cmd += " from \(shellQuoted(from)) to any port \(shellQuoted(port))"
            if let proto { cmd += " proto \(proto)" }
        } else {
            cmd += " " + shellQuoted(proto.map { "\(port)/\($0)" } ?? port)
        }
        try await ShellService.shared.sshExpectingSuccess(server, command: cmd)
    }

    func deleteRule(_ server: Server, number: Int) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n ufw --force delete \(number)")
    }

    /// Always allows the port this app is connected over *before* turning the
    /// firewall on, so enabling it can never lock you out of the server.
    func enable(_ server: Server) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n ufw allow \(server.port)/tcp && sudo -n ufw --force enable")
    }

    func disable(_ server: Server) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n ufw disable")
    }
}
