import Foundation

/// One MCP tool: its schema for `tools/list`, the access it needs, and its handler.
struct MCPTool {
    let name: String
    let title: String
    let description: String
    var properties: [String: [String: Any]] = [:]
    var required: [String] = []
    /// Takes a `server` argument (added to the schema automatically).
    var needsServer = true
    /// `.readOnly` tools work on read-only and full servers; `.full` only on full.
    var requires: AgentAccess = .readOnly
    var destructive = false
    let run: (Arguments, Server?, MCPConfig) async throws -> String
    /// One-line description of a call for the activity log.
    var summarize: (Arguments) -> String = { _ in "" }

    var descriptor: [String: Any] {
        var props = properties
        var req = required
        if needsServer {
            props["server"] = ["type": "string", "description": "Server name, id or user@host (see list_servers)."]
            req.insert("server", at: 0)
        }
        return [
            "name": name,
            "title": title,
            "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": req],
            "annotations": [
                "title": title,
                "readOnlyHint": requires != .full,
                "destructiveHint": destructive,
                "openWorldHint": true,
            ],
        ]
    }
}

private func prop(_ type: String, _ description: String, enumValues: [String]? = nil) -> [String: Any] {
    var p: [String: Any] = ["type": type, "description": description]
    if let enumValues { p["enum"] = enumValues }
    return p
}

private func output(_ result: ShellResult) -> String {
    var text = result.stdout.trimmingCharacters(in: .newlines)
    let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if !err.isEmpty { text += (text.isEmpty ? "" : "\n") + "[stderr]\n" + err }
    return "exit code: \(result.exitCode)\n" + (text.isEmpty ? "(no output)" : text)
}

/// Expands a leading `~` against the remote user's home (our file helpers quote
/// paths, so the remote shell never expands it).
private func remotePath(_ path: String, on server: Server) async throws -> String {
    guard path == "~" || path.hasPrefix("~/") else { return path }
    let home = try await ShellService.shared.sshExpectingSuccess(server, command: "printf %s \"$HOME\"")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return home + path.dropFirst()
}

private func bytes(_ value: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
}

extension MCPServer {
    static let tools: [MCPTool] = [
        // MARK: Servers
        MCPTool(
            name: "list_servers",
            title: "List servers",
            description: "Lists the servers you may use, with your access level on each (read_only or full) and their linked projects.",
            needsServer: false,
            run: { _, _, config in
                let servers = MCPServer.visibleServers(config)
                guard !servers.isEmpty else {
                    return "No servers are enabled for AI agents. The user can enable them in VPS Manager ▸ Settings ▸ AI Agents."
                }
                let projects = DiskStore.shared.load("projects.json", as: [Project].self, default: [])
                return servers.map { s in
                    var line = "- \(s.nickname): \(s.sshTarget)\(s.port == 22 ? "" : " port \(s.port)") — access: \(config.access(for: s.id) == .full ? "full" : "read_only") — id \(s.id.uuidString)"
                    for p in projects where p.serverID == s.id {
                        line += "\n    project \"\(p.name)\": \(p.localPath) → \(p.remotePath)"
                    }
                    return line
                }.joined(separator: "\n")
            }
        ),
        MCPTool(
            name: "server_status",
            title: "Server status",
            description: "OS, uptime, CPU load, memory and disk usage of a server.",
            run: { _, server, _ in
                let cmd = """
                echo "Hostname: $(hostname)"; echo "OS: $( (. /etc/os-release && echo "$PRETTY_NAME") 2>/dev/null)"; \
                echo "Kernel: $(uname -sr)"; echo "Uptime: $(uptime -p 2>/dev/null)"; \
                echo "CPU cores: $(nproc)"; echo "Load (1/5/15m): $(cut -d' ' -f1-3 /proc/loadavg)"; \
                free -h | awk '/Mem:/ {print "Memory: " $3 " used of " $2 " (" $7 " available)"}'; \
                df -h / | awk 'NR==2 {print "Disk /: " $3 " used of " $2 " (" $5 ")"}'
                """
                return try await ShellService.shared.sshExpectingSuccess(server!, command: cmd)
            }
        ),
        MCPTool(
            name: "run_command",
            title: "Run shell command",
            description: "Runs a shell command on the server in a bash login shell and returns its exit code, stdout and stderr. Non-interactive: no TTY, no password prompts (use `sudo -n`). Requires full access.",
            properties: [
                "command": prop("string", "The bash command to run."),
                "working_directory": prop("string", "Directory to run in (default: the user's home)."),
                "timeout_seconds": prop("integer", "Kill the command after this many seconds (default 60, max 600)."),
            ],
            required: ["command"],
            requires: .full,
            destructive: true,
            run: { args, server, _ in
                var command = try args.requiredString("command")
                if let dir = args.string("working_directory"), !dir.isEmpty {
                    let path = try await remotePath(dir, on: server!)
                    command = "cd \(shellQuoted(path)) && " + command
                }
                let timeout = args.int("timeout_seconds", default: 60, range: 1...600)
                return output(try await ShellService.shared.ssh(server!, command: command, timeout: TimeInterval(timeout)))
            },
            summarize: { $0.string("command") ?? "" }
        ),

        // MARK: Files
        MCPTool(
            name: "list_directory",
            title: "List directory",
            description: "Lists a directory on the server: type, size, permissions, modified time and name of each entry.",
            properties: ["path": prop("string", "Directory path (default ~).")],
            run: { args, server, _ in
                let path = try await remotePath(args.string("path") ?? "~", on: server!)
                let files = try await SFTPService.shared.list(server!, path: path)
                if files.isEmpty { return "\(path) is empty (or not readable)." }
                let formatter = ISO8601DateFormatter()
                return "\(path)\n" + files.map { f in
                    let kind = f.isDirectory ? "dir " : "file"
                    let link = f.isSymlink ? " (symlink)" : ""
                    let date = f.modifiedAt.map { formatter.string(from: $0) } ?? ""
                    return "\(kind)  \(f.permissions)  \(String(f.sizeBytes).padding(toLength: 10, withPad: " ", startingAt: 0))  \(date)  \(f.name)\(link)"
                }.joined(separator: "\n")
            },
            summarize: { $0.string("path") ?? "~" }
        ),
        MCPTool(
            name: "read_file",
            title: "Read file",
            description: "Reads a text file from the server (up to max_bytes, default 200 KB).",
            properties: [
                "path": prop("string", "File path."),
                "max_bytes": prop("integer", "Maximum bytes to read (default 200000, max 1000000)."),
            ],
            required: ["path"],
            run: { args, server, _ in
                let path = try await remotePath(try args.requiredString("path"), on: server!)
                let limit = args.int("max_bytes", default: 200_000, range: 1...1_000_000)
                let quoted = shellQuoted(path)
                let cmd = "test -f \(quoted) || { echo \"not a regular file: \(path.replacingOccurrences(of: "\"", with: ""))\" >&2; exit 2; }; stat -c %s \(quoted); head -c \(limit) -- \(quoted) | base64 -w0"
                let out = try await ShellService.shared.sshExpectingSuccess(server!, command: cmd, timeout: 60)
                let lines = out.split(separator: "\n", maxSplits: 1).map(String.init)
                let size = Int(lines.first ?? "") ?? 0
                let data = Data(base64Encoded: lines.count > 1 ? lines[1].trimmingCharacters(in: .whitespacesAndNewlines) : "") ?? Data()
                if data.contains(0) { return "\(path) looks like a binary file (\(size) bytes); not shown." }
                let text = String(decoding: data, as: UTF8.self)
                return size > limit ? text + "\n… [file is \(size) bytes; showing the first \(limit)]" : text
            },
            summarize: { $0.string("path") ?? "" }
        ),
        MCPTool(
            name: "write_file",
            title: "Write file",
            description: "Writes text to a file on the server, replacing it (or appending with append=true). Creates parent directories. Requires full access.",
            properties: [
                "path": prop("string", "File path."),
                "content": prop("string", "Text to write."),
                "append": prop("boolean", "Append instead of replacing (default false)."),
            ],
            required: ["path", "content"],
            requires: .full,
            destructive: true,
            run: { args, server, _ in
                let path = try await remotePath(try args.requiredString("path"), on: server!)
                let content = args.string("content") ?? ""
                let quoted = shellQuoted(path)
                let dir = shellQuoted((path as NSString).deletingLastPathComponent)
                let redirect = args.bool("append", default: false) ? ">>" : ">"
                let cmd = "mkdir -p \(dir) && base64 -d \(redirect) \(quoted)"
                let result = try await ShellService.shared.run("ssh", server!.sshArgs + [cmd],
                                                               input: Data(content.utf8).base64EncodedString(), timeout: 120)
                guard result.success else { throw ToolError(result.stderr.isEmpty ? "Write failed (exit \(result.exitCode))." : result.stderr) }
                return "Wrote \(content.utf8.count) bytes to \(path)."
            },
            summarize: { "\($0.string("path") ?? "") (\(($0.string("content") ?? "").utf8.count) bytes)" }
        ),

        // MARK: PM2
        MCPTool(
            name: "pm2_list",
            title: "PM2 processes",
            description: "Lists PM2 processes with status, CPU, memory, uptime and restart count.",
            run: { _, server, _ in
                let list = try await PM2Service.shared.fetchStatuses(server!)
                if list.isEmpty { return "No PM2 processes." }
                return list.map {
                    "\($0.name) [id \($0.id)]: \($0.status), cpu \(Int($0.cpu))%, mem \(Int($0.memoryMB)) MB, restarts \($0.restarts)"
                }.joined(separator: "\n")
            }
        ),
        MCPTool(
            name: "pm2_logs",
            title: "PM2 logs",
            description: "Recent log lines of a PM2 process.",
            properties: [
                "name": prop("string", "PM2 process name."),
                "lines": prop("integer", "Number of lines (default 100, max 2000)."),
                "errors": prop("boolean", "Show the error log instead of stdout (default false)."),
            ],
            required: ["name"],
            run: { args, server, _ in
                let name = try args.requiredString("name")
                let lines = args.int("lines", default: 100, range: 1...2000)
                let kind: PM2Service.LogKind = args.bool("errors", default: false) ? .err : .out
                return try await PM2Service.shared.tailLogs(server!, name: name, kind: kind, lines: lines).strippingANSICodes()
            },
            summarize: { $0.string("name") ?? "" }
        ),
        MCPTool(
            name: "pm2_action",
            title: "Control PM2 process",
            description: "Restarts, stops or deletes a PM2 process. Requires full access.",
            properties: [
                "name": prop("string", "PM2 process name."),
                "action": prop("string", "What to do.", enumValues: ["restart", "stop", "delete"]),
            ],
            required: ["name", "action"],
            requires: .full,
            destructive: true,
            run: { args, server, _ in
                let name = try args.requiredString("name")
                switch try args.requiredString("action") {
                case "restart": try await PM2Service.shared.restart(server!, name: name)
                case "stop": try await PM2Service.shared.stop(server!, name: name)
                case "delete": try await PM2Service.shared.delete(server!, name: name)
                case let other: throw ToolError("Unknown action `\(other)`.")
                }
                return "pm2 \(args.string("action")!) \(name): done."
            },
            summarize: { "\($0.string("action") ?? "") \($0.string("name") ?? "")" }
        ),

        // MARK: systemd
        MCPTool(
            name: "systemd_status",
            title: "systemd services",
            description: "Status of systemd units. Without `units`, reports the services the user tracks in VPS Manager.",
            properties: ["units": prop("string", "Comma-separated unit names, e.g. \"nginx, myapp.service\".")],
            run: { args, server, _ in
                var units = (args.string("units") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                if units.isEmpty {
                    let tracked = DiskStore.shared.load("systemd_units.json", as: [TrackedSystemdUnit].self, default: [])
                    units = tracked.filter { $0.serverID == server!.id }.map(\.unitName)
                    if units.isEmpty { units = SystemdService.shared.defaultUnits }
                }
                let statuses = try await SystemdService.shared.statuses(server!, units: units)
                if statuses.isEmpty { return "None of these units exist: \(units.joined(separator: ", "))" }
                return statuses.map { "\($0.name): \($0.activeState) (\($0.subState))\($0.enabled ? ", enabled at boot" : "")" }.joined(separator: "\n")
            }
        ),
        MCPTool(
            name: "systemd_logs",
            title: "systemd journal",
            description: "Recent journal lines for a systemd unit.",
            properties: [
                "unit": prop("string", "Unit name, e.g. nginx."),
                "lines": prop("integer", "Number of lines (default 100, max 2000)."),
            ],
            required: ["unit"],
            run: { args, server, _ in
                let unit = shellQuoted(try args.requiredString("unit"))
                let lines = args.int("lines", default: 100, range: 1...2000)
                let cmd = "if sudo -n true 2>/dev/null; then sudo -n journalctl -u \(unit) -n \(lines) --no-pager; else journalctl -u \(unit) -n \(lines) --no-pager; fi"
                return output(try await ShellService.shared.ssh(server!, command: cmd, timeout: 60))
            },
            summarize: { $0.string("unit") ?? "" }
        ),
        MCPTool(
            name: "systemd_action",
            title: "Control systemd unit",
            description: "Starts, stops, restarts, enables or disables a systemd unit (needs passwordless sudo). Requires full access.",
            properties: [
                "unit": prop("string", "Unit name."),
                "action": prop("string", "What to do.", enumValues: ["start", "stop", "restart", "enable", "disable"]),
            ],
            required: ["unit", "action"],
            requires: .full,
            destructive: true,
            run: { args, server, _ in
                let unit = try args.requiredString("unit")
                let action = try args.requiredString("action")
                guard ["start", "stop", "restart", "enable", "disable"].contains(action) else { throw ToolError("Unknown action `\(action)`.") }
                try await ShellService.shared.sshExpectingSuccess(server!, command: "sudo -n systemctl \(action) \(shellQuoted(unit))")
                return "systemctl \(action) \(unit): done."
            },
            summarize: { "\($0.string("action") ?? "") \($0.string("unit") ?? "")" }
        ),

        // MARK: Docker
        MCPTool(
            name: "docker_containers",
            title: "Docker containers",
            description: "Lists Docker containers (running and stopped) with image, status, ports and live CPU / memory.",
            run: { _, server, _ in
                let (availability, list) = try await DockerService.shared.containers(server!)
                switch availability {
                case .notInstalled: return "Docker isn't installed on this server."
                case .noPermission: return "The SSH user can't access the Docker daemon (not in the docker group, no passwordless sudo)."
                case .available: break
                }
                if list.isEmpty { return "No containers." }
                return list.map {
                    "\($0.name) [\($0.id)] image=\($0.image) state=\($0.state) status=\"\($0.status)\" ports=\"\($0.ports)\" cpu=\($0.cpu ?? "-") mem=\($0.memory ?? "-")"
                }.joined(separator: "\n")
            }
        ),
        MCPTool(
            name: "docker_logs",
            title: "Docker logs",
            description: "Recent log lines of a Docker container.",
            properties: [
                "container": prop("string", "Container name or id."),
                "lines": prop("integer", "Number of lines (default 100, max 2000)."),
            ],
            required: ["container"],
            run: { args, server, _ in
                let container = shellQuoted(try args.requiredString("container"))
                let lines = args.int("lines", default: 100, range: 1...2000)
                let cmd = "D=docker; docker ps -q >/dev/null 2>&1 || D=\"sudo -n docker\"; $D logs --tail \(lines) \(container) 2>&1"
                return output(try await ShellService.shared.ssh(server!, command: cmd, timeout: 60))
            },
            summarize: { $0.string("container") ?? "" }
        ),
        MCPTool(
            name: "docker_action",
            title: "Control Docker container",
            description: "Starts, stops, restarts or removes a Docker container. Requires full access.",
            properties: [
                "container": prop("string", "Container name or id."),
                "action": prop("string", "What to do.", enumValues: ["start", "stop", "restart", "remove"]),
            ],
            required: ["container", "action"],
            requires: .full,
            destructive: true,
            run: { args, server, _ in
                let name = try args.requiredString("container")
                let action: DockerService.ContainerAction
                switch try args.requiredString("action") {
                case "start": action = .start
                case "stop": action = .stop
                case "restart": action = .restart
                case "remove": action = .remove
                case let other: throw ToolError("Unknown action `\(other)`.")
                }
                let target = DockerContainer(id: name, name: name, image: "", state: "", status: "", ports: "")
                try await DockerService.shared.perform(action, on: target, server: server!)
                return "docker \(args.string("action")!) \(name): done."
            },
            summarize: { "\($0.string("action") ?? "") \($0.string("container") ?? "")" }
        ),

        // MARK: Network
        MCPTool(
            name: "network_ports",
            title: "Listening ports",
            description: "TCP/UDP ports listening on the server, their bind address and owning process.",
            run: { _, server, _ in
                let ports = try await NetworkService.shared.listeningPorts(server!)
                return ports.map {
                    "\($0.proto) \($0.port) on \($0.address)\($0.isLocalOnly ? " (localhost only)" : "") — \($0.process ?? "unknown process")"
                }.joined(separator: "\n")
            }
        ),
        MCPTool(
            name: "firewall_status",
            title: "Firewall rules",
            description: "ufw firewall state and numbered rules.",
            run: { _, server, _ in
                let status = try await NetworkService.shared.firewall(server!)
                guard status.installed else { return "ufw is not installed." }
                let rules = status.rules.map { "[\($0.number)] \($0.target) \($0.action) from \($0.from)" }
                return "ufw is \(status.active ? "active" : "inactive")\n" + (rules.isEmpty ? "(no rules)" : rules.joined(separator: "\n"))
            }
        ),

        // MARK: Projects
        MCPTool(
            name: "project_diff",
            title: "Preview project sync",
            description: "Shows what pushing a linked project (local Mac folder → server folder) would create, update or delete, without changing anything.",
            properties: ["project": prop("string", "Project name (see list_servers).")],
            required: ["project"],
            run: { args, server, _ in
                let project = try findProject(try args.requiredString("project"), on: server!)
                let changes = try await SyncService.shared.previewChanges(server: server!, project: project)
                if changes.isEmpty { return "\(project.name) is in sync." }
                return "\(changes.count) change(s) for \(project.name) (\(project.localPath) → \(project.remotePath)):\n" +
                    changes.map { "\($0.kind.rawValue): \($0.path)" }.joined(separator: "\n")
            },
            summarize: { $0.string("project") ?? "" }
        ),
        MCPTool(
            name: "project_push",
            title: "Push project",
            description: "Pushes a linked project from the Mac to the server with rsync, including deleting server files that were removed locally. Run project_diff first. Requires full access.",
            properties: ["project": prop("string", "Project name (see list_servers).")],
            required: ["project"],
            requires: .full,
            destructive: true,
            run: { args, server, _ in
                let project = try findProject(try args.requiredString("project"), on: server!)
                var log = ""
                try await SyncService.shared.push(server: server!, project: project, deleteRemoved: true) { log += $0 }
                var projects = DiskStore.shared.load("projects.json", as: [Project].self, default: [])
                if let index = projects.firstIndex(where: { $0.id == project.id }) {
                    projects[index].lastSyncedAt = Date()
                    DiskStore.shared.save(projects, to: "projects.json")
                }
                return "Pushed \(project.name).\n" + log
            },
            summarize: { $0.string("project") ?? "" }
        ),
    ]

    private static func findProject(_ name: String, on server: Server) throws -> Project {
        let projects = DiskStore.shared.load("projects.json", as: [Project].self, default: []).filter { $0.serverID == server.id }
        if let match = projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return match }
        throw ToolError("No project named `\(name)` on \(server.nickname). Projects: \(projects.map(\.name).joined(separator: ", ").isEmpty ? "none" : projects.map(\.name).joined(separator: ", "))")
    }
}
