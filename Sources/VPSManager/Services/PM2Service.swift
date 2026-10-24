import Foundation

final class PM2Service {
    static let shared = PM2Service()

    struct JListEntry: Decodable {
        struct Monit: Decodable { let cpu: Double; let memory: Double }
        struct PM2Env: Decodable {
            let pm_uptime: Double?
            let status: String
            let restart_time: Int?
        }
        let pm_id: Int
        let name: String
        let monit: Monit
        let pm2_env: PM2Env
    }

    func fetchStatuses(_ server: Server) async throws -> [PM2ProcessStatus] {
        let output = try await ShellService.shared.sshExpectingSuccess(server, command: "pm2 jlist 2>/dev/null")
        guard let data = output.data(using: .utf8),
              let entries = try? JSONDecoder().decode([JListEntry].self, from: data) else {
            return []
        }
        let now = Date().timeIntervalSince1970 * 1000
        return entries.map {
            PM2ProcessStatus(
                id: $0.pm_id,
                name: $0.name,
                status: $0.pm2_env.status,
                cpu: $0.monit.cpu,
                memoryMB: $0.monit.memory / 1024 / 1024,
                uptimeMs: $0.pm2_env.pm_uptime.map { max(0, now - $0) } ?? 0,
                restarts: $0.pm2_env.restart_time ?? 0
            )
        }
    }

    func tailLogs(_ server: Server, name: String, kind: LogKind, lines: Int = 200) async throws -> String {
        let flag = kind == .out ? "--out" : "--err"
        let cmd = "pm2 logs \(name) \(flag) --lines \(lines) --nostream 2>/dev/null"
        return try await ShellService.shared.sshExpectingSuccess(server, command: cmd)
    }

    enum LogKind { case out, err }

    func restart(_ server: Server, name: String) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "pm2 restart \(name)")
    }
    func stop(_ server: Server, name: String) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "pm2 stop \(name)")
    }
    func delete(_ server: Server, name: String) async throws {
        try await ShellService.shared.sshExpectingSuccess(server, command: "pm2 delete \(name)")
    }

    /// Deploys a PM2 app: writes ecosystem file, optionally sets up a venv + installs
    /// requirements for Python apps, starts it, then persists with `pm2 save` and
    /// ensures `pm2 startup` (systemd) is configured so it survives reboots.
    func deploy(_ server: Server, config: PM2AppConfig, requirementsPath: String?, progress: @escaping (String) -> Void) async throws {
        if config.type == .python && !config.venvPath.isEmpty {
            progress("Checking Python venv at \(config.venvPath)...\n")
            let venvCheck = try await ShellService.shared.ssh(server, command: "test -d '\(config.venvPath)' && echo YES || echo NO")
            if !venvCheck.stdout.contains("YES") {
                progress("Creating venv...\n")
                try await ShellService.shared.sshExpectingSuccess(server, command: "python3 -m venv '\(config.venvPath)'")
            }
            if let req = requirementsPath, !req.isEmpty {
                progress("Installing requirements from \(req)...\n")
                let cmd = "'\(config.venvPath)/bin/pip' install -r '\(req)'"
                try await ShellService.shared.sshExpectingSuccess(server, command: cmd)
            }
        }

        let ecosystemPath = "\(config.remoteCwd)/ecosystem.\(config.name).config.js"
        progress("Writing ecosystem config to \(ecosystemPath)...\n")
        try await SFTPService.shared.writeFile(server, path: ecosystemPath, contents: config.ecosystemJS())

        progress("Starting with pm2...\n")
        try await ShellService.shared.sshExpectingSuccess(server, command: "pm2 start '\(ecosystemPath)'")

        progress("Saving pm2 process list...\n")
        try await ShellService.shared.sshExpectingSuccess(server, command: "pm2 save")

        progress("Ensuring pm2 starts on boot (systemd)...\n")
        let startupCheck = try await ShellService.shared.ssh(server, command: "systemctl is-enabled pm2-\(server.user) 2>/dev/null")
        if !startupCheck.stdout.contains("enabled") {
            let startupCmd = "env PATH=$PATH:/usr/bin pm2 startup systemd -u \(server.user) --hp /home/\(server.user)"
            let r = try await ShellService.shared.ssh(server, command: startupCmd)
            // pm2 startup prints a `sudo env ... pm2 startup ...` command that must be run as root.
            if let sudoLine = r.stdout.split(separator: "\n").first(where: { $0.contains("sudo env") }) {
                progress("Running startup registration command...\n")
                try await ShellService.shared.sshExpectingSuccess(server, command: String(sudoLine))
            }
            try await ShellService.shared.sshExpectingSuccess(server, command: "pm2 save")
        }
        progress("✅ \(config.name) deployed and persisted.\n")
    }

    /// Lists existing Python venvs under a project directory (for the venv chooser).
    func discoverVenvs(_ server: Server, underPath: String) async throws -> [String] {
        let cmd = "find '\(underPath)' -maxdepth 3 -type f -name 'pyvenv.cfg' 2>/dev/null"
        let output = try await ShellService.shared.ssh(server, command: cmd)
        return output.stdout.split(separator: "\n").map {
            String($0).replacingOccurrences(of: "/pyvenv.cfg", with: "")
        }
    }

    func discoverRequirementsFiles(_ server: Server, underPath: String) async throws -> [String] {
        let cmd = "find '\(underPath)' -maxdepth 2 -type f -iname 'requirements*.txt' 2>/dev/null"
        let output = try await ShellService.shared.ssh(server, command: cmd)
        return output.stdout.split(separator: "\n").map(String.init)
    }
}
