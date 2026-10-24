import Foundation

final class CloudflaredService {
    static let shared = CloudflaredService()

    func isLoggedIn(_ server: Server) async throws -> Bool {
        let r = try await ShellService.shared.ssh(server, command: "test -f /etc/cloudflared/cert.pem -o -f ~/.cloudflared/cert.pem && echo YES || echo NO")
        return r.stdout.contains("YES")
    }

    /// Kicks off `cloudflared tunnel login`, which prints an auth URL the user must open.
    /// Returns the URL to open in their browser; caller polls for completion.
    func beginLogin(_ server: Server, onURL: @escaping (String) -> Void) async throws {
        let pty = PTYProcess()
        var didEmit = false
        pty.onOutput = { chunk in
            if !didEmit, let range = chunk.range(of: "https://") {
                let url = String(chunk[range.lowerBound...]).split(separator: "\n").first.map(String.init) ?? ""
                if !url.isEmpty { didEmit = true; onURL(url) }
            }
        }
        _ = pty.start(executable: "ssh", arguments: server.sshArgs + ["bash -ilc 'cloudflared tunnel login'"], environment: ProcessInfo.processInfo.environment)
    }

    func existingTunnels(_ server: Server) async throws -> [(name: String, id: String)] {
        let output = try await ShellService.shared.ssh(server, command: "cloudflared tunnel list 2>/dev/null")
        var results: [(String, String)] = []
        for line in output.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, looksLikeTunnelID(String(parts[0])) else { continue }
            results.append((name: String(parts[1]), id: String(parts[0])))
        }
        return results
    }

    /// Real tunnel IDs are always UUIDs. Checking the shape instead of blindly
    /// skipping "the first line" is what actually makes this robust — an interactive
    /// login shell can print MOTD/profile banner lines before cloudflared's real
    /// output, which shifts everything by however many extra lines got printed and
    /// otherwise lets the column header row ("ID  NAME  CREATED...") get parsed as
    /// if "NAME" were a real tunnel.
    private func looksLikeTunnelID(_ s: String) -> Bool {
        let segments = s.split(separator: "-").map(String.init)
        guard segments.count == 5 else { return false }
        let lengths = [8, 4, 4, 4, 12]
        for (segment, expected) in zip(segments, lengths) {
            guard segment.count == expected, segment.allSatisfy({ $0.isHexDigit }) else { return false }
        }
        return true
    }

    /// Creates a new tunnel if it doesn't exist, adds an ingress route, updates DNS, and (re)starts the service.
    func createOrUpdateTunnelAndRoute(
        server: Server,
        tunnelName: String,
        hostname: String,
        localPort: Int,
        configPath: String? = nil,
        systemdUnit: String? = nil,
        credentialsFile: String? = nil,
        progress: @escaping (String) -> Void
    ) async throws -> (tunnelID: String, credentialsFile: String, configPath: String, systemdUnit: String) {

        progress("Checking for existing tunnel '\(tunnelName)'...\n")
        let existing = try await existingTunnels(server)
        var tunnelID = existing.first(where: { $0.name == tunnelName })?.id ?? ""
        var credsFile = ""

        if tunnelID.isEmpty {
            progress("Creating tunnel '\(tunnelName)'...\n")
            let createOut = try await ShellService.shared.sshExpectingSuccess(
                server,
                command: "cloudflared tunnel create \(shellQuote(tunnelName))"
            )
            progress(createOut)
            // Output includes: "Created tunnel <name> with id <uuid>"
            if let range = createOut.range(of: "with id ") {
                tunnelID = String(createOut[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
            }
            guard looksLikeTunnelID(tunnelID) else {
                throw NSError(domain: "CloudflaredService", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "cloudflared created the tunnel but did not return a valid tunnel ID."
                ])
            }
            credsFile = try await findCredentialsFile(server: server, tunnelID: tunnelID)
        } else {
            progress("Found existing tunnel with id \(tunnelID)\n")
            if let credentialsFile, !credentialsFile.isEmpty {
                credsFile = credentialsFile
            } else {
                credsFile = try await findCredentialsFile(server: server, tunnelID: tunnelID)
            }
        }

        let generated = uniqueConfigLocation(tunnelName: tunnelName, tunnelID: tunnelID)
        let suppliedConfigPath = configPath.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedConfigPath = suppliedConfigPath ?? generated.configPath
        let requestedUnit = systemdUnit.flatMap { $0.isEmpty ? nil : $0 }
        let resolvedUnit = suppliedConfigPath == nil ? generated.systemdUnit : (requestedUnit ?? generated.systemdUnit)

        progress("Reading \(resolvedConfigPath)...\n")
        var configText = ""
        let configCheck = try await ShellService.shared.ssh(
            server,
            command: "test -f \(shellQuote(resolvedConfigPath)) && echo YES || echo NO"
        )
        guard configCheck.success else {
            throw NSError(domain: "CloudflaredService", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Could not check for the existing tunnel configuration at \(resolvedConfigPath)."
            ])
        }
        if configCheck.stdout.contains("YES") {
            configText = try await SFTPService.shared.readFile(server, path: resolvedConfigPath)
        }

        let newConfig = ConfigYAMLBuilder.upsertIngress(
            existingYAML: configText,
            tunnelID: tunnelID,
            credentialsFile: credsFile,
            hostname: hostname,
            localPort: localPort
        )

        progress("Writing \(resolvedConfigPath)...\n")
        let privilege = privilegePrefix(for: server)
        try await ShellService.shared.sshExpectingSuccess(
            server,
            command: "\(privilege)mkdir -p \(shellQuote((resolvedConfigPath as NSString).deletingLastPathComponent))"
        )
        try await writePrivilegedFile(server: server, path: resolvedConfigPath, contents: newConfig)

        progress("Routing DNS: \(hostname) → tunnel \(tunnelName)...\n")
        try await ShellService.shared.sshExpectingSuccess(
            server,
            command: "cloudflared tunnel route dns -f \(shellQuote(tunnelName)) \(shellQuote(hostname))"
        )

        progress("Installing/restarting \(resolvedUnit)...\n")
        try await installOrRestartService(
            server: server,
            unit: resolvedUnit,
            configPath: resolvedConfigPath
        )

        progress("✅ Route \(hostname) → localhost:\(localPort) is live.\n")
        return (tunnelID, credsFile, resolvedConfigPath, resolvedUnit)
    }

    private func uniqueConfigLocation(tunnelName: String, tunnelID: String) -> (configPath: String, systemdUnit: String) {
        let slug = tunnelName.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains(scalar) ? Character(scalar) : "-"
        }
        let cleaned = String(slug).split(separator: "-").joined(separator: "-")
        let name = String(cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(32))
        let safeName = name.isEmpty ? "tunnel" : name
        let suffix = tunnelID.lowercased()
        return (
            "/etc/cloudflared/\(safeName)-\(suffix).yml",
            "cloudflared-\(safeName)-\(suffix)"
        )
    }

    private func installOrRestartService(server: Server, unit: String, configPath: String) async throws {
        guard !unit.isEmpty, !unit.contains("/"), !unit.contains("\\"),
              !unit.contains(where: \.isWhitespace) else {
            throw NSError(domain: "CloudflaredService", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "The systemd unit name is invalid."
            ])
        }
        let check = try await ShellService.shared.ssh(
            server,
            command: "systemctl cat \(shellQuote(unit)) >/dev/null 2>&1"
        )
        if check.success {
            try await ShellService.shared.sshExpectingSuccess(
                server,
                command: "\(privilegePrefix(for: server))systemctl restart \(shellQuote(unit))"
            )
            return
        }

        let binary = try await ShellService.shared.sshExpectingSuccess(
            server,
            command: "command -v cloudflared | tail -n 1"
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard binary.hasPrefix("/") else {
            throw NSError(domain: "CloudflaredService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not resolve the cloudflared executable path for the systemd service."
            ])
        }

        let serviceContents = """
        [Unit]
        Description=Cloudflare Tunnel \(unit)
        After=network-online.target
        Wants=network-online.target

        [Service]
        Type=simple
        ExecStart=\(binary) --config \(configPath) tunnel run
        Restart=on-failure
        User=root

        [Install]
        WantedBy=multi-user.target
        """
        guard let data = serviceContents.data(using: .utf8) else {
            throw NSError(domain: "CloudflaredService", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Could not encode the tunnel service configuration."
            ])
        }
        let encoded = data.base64EncodedString()
        let unitFileName = unit.hasSuffix(".service") ? unit : "\(unit).service"
        let unitPath = "/etc/systemd/system/\(unitFileName)"
        let privilege = privilegePrefix(for: server)
        let command = """
        printf '%s' '\(encoded)' | \(privilege)tee \(shellQuote(unitPath)) >/dev/null &&
        \(privilege)systemctl daemon-reload &&
        \(privilege)systemctl enable --now \(shellQuote(unit))
        """
        try await ShellService.shared.sshExpectingSuccess(server, command: command)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func findCredentialsFile(server: Server, tunnelID: String) async throws -> String {
        let candidates = ["/root/.cloudflared/\(tunnelID).json", "/home/\(server.user)/.cloudflared/\(tunnelID).json"]
        for path in candidates {
            let result = try await ShellService.shared.ssh(
                server,
                command: "test -s \(shellQuote(path)) && echo YES || echo NO"
            )
            if result.success && result.stdout.contains("YES") {
                return path
            }
        }
        throw NSError(domain: "CloudflaredService", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "The credentials file for tunnel \(tunnelID) could not be found in the root or \(server.user) Cloudflare directory."
        ])
    }

    private func privilegePrefix(for server: Server) -> String {
        server.user == "root" ? "" : "sudo -n "
    }

    private func writePrivilegedFile(server: Server, path: String, contents: String) async throws {
        let encoded = Data(contents.utf8).base64EncodedString()
        let privilege = privilegePrefix(for: server)
        let parent = (path as NSString).deletingLastPathComponent
        let command = """
        \(privilege)mkdir -p \(shellQuote(parent)) &&
        printf '%s' '\(encoded)' | \(privilege)tee \(shellQuote(path)) >/dev/null
        """
        try await ShellService.shared.sshExpectingSuccess(server, command: command)
    }

    func removeRoute(server: Server, configPath: String, hostname: String, unit: String = "cloudflared", progress: @escaping (String) -> Void) async throws {
        let existingConfig = try await SFTPService.shared.readFile(server, path: configPath)
        let updated = ConfigYAMLBuilder.removeIngress(existingYAML: existingConfig, hostname: hostname)
        try await writePrivilegedFile(server: server, path: configPath, contents: updated)
        try await ShellService.shared.sshExpectingSuccess(
            server,
            command: "\(privilegePrefix(for: server))systemctl restart \(shellQuote(unit))"
        )
        progress("Removed route for \(hostname) and restarted \(unit).\n")
    }

    func saveConfig(server: Server, configPath: String, contents: String) async throws {
        try await writePrivilegedFile(server: server, path: configPath, contents: contents)
    }

    /// Writes raw YAML to a config path and restarts the given systemd unit so the
    /// change actually takes effect — used by the in-app config editor.
    func saveConfigAndRestart(server: Server, configPath: String, contents: String, unit: String) async throws {
        try await saveConfig(server: server, configPath: configPath, contents: contents)
        try await ShellService.shared.sshExpectingSuccess(
            server,
            command: "\(privilegePrefix(for: server))systemctl restart \(shellQuote(unit))"
        )
    }
    /// Scans the server for tunnels that already exist (created manually, outside the
    /// app's own wizard) so the user can import them instead of the UI just showing
    /// "no tunnels" forever.
    ///
    /// This is systemd-driven rather than path-guessing: it finds every unit whose
    /// name starts with "cloudflared" (catching per-tunnel units like
    /// `cloudflared-api.service` and `cloudflared-web.service`, not just the
    /// default `cloudflared.service`), reads each one's *actual* `--config` argument
    /// straight out of its `ExecStart=` line via `systemctl cat`, and only then reads
    /// that specific file. That's authoritative — it can't confuse two tunnels that
    /// happen to both have a config file at a conventional-looking path, because it's
    /// reading the exact path each service was told to use, not guessing at one.
    func discoverExisting(_ server: Server) async throws -> [DiscoveredTunnel] {
        let knownTunnels = try await existingTunnels(server)

        let combined = """
        for u in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}' | grep -E '^cloudflared'); do
          unit="${u%.service}"
          execline=$(systemctl cat "$u" 2>/dev/null | grep -m1 '^ExecStart=')
          echo "###UNIT###$unit"
          echo "###EXEC###$execline"
        done
        """
        let output = (try? await ShellService.shared.ssh(server, command: combined, timeout: 20))?.stdout ?? ""

        // Parse into (unit, execStartLine) pairs.
        var unitExecPairs: [(unit: String, exec: String)] = []
        var pendingUnit: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let str = String(line)
            if str.hasPrefix("###UNIT###") {
                pendingUnit = String(str.dropFirst("###UNIT###".count))
            } else if str.hasPrefix("###EXEC###"), let unit = pendingUnit {
                unitExecPairs.append((unit, String(str.dropFirst("###EXEC###".count))))
                pendingUnit = nil
            }
        }

        var results: [DiscoveredTunnel] = []
        for (unit, execLine) in unitExecPairs {
            guard let configPath = extractConfigPath(fromExecStart: execLine) else {
                // Unit exists but doesn't run with an explicit --config flag (e.g. uses
                // cloudflared's own default lookup) — still worth surfacing so the user
                // can correct it manually rather than it silently vanishing.
                results.append(DiscoveredTunnel(name: unit, tunnelID: "", configPath: "", systemdUnit: unit, routes: []))
                continue
            }

            let configContents = (try? await SFTPService.shared.readFile(server, path: configPath)) ?? ""
            let routes = ConfigYAMLBuilder.parseIngress(configContents)
            let tunnelIDFromConfig = extractTunnelID(fromConfig: configContents)

            // Prefer the friendly name from `cloudflared tunnel list` if the config's
            // tunnel id matches a known tunnel; otherwise fall back to the unit's own
            // name (stripping a "cloudflared-" prefix, since that's the convention
            // these units were created with).
            let friendlyName = knownTunnels.first(where: { $0.id == tunnelIDFromConfig })?.name
                ?? unit.replacingOccurrences(of: "cloudflared-", with: "")

            results.append(DiscoveredTunnel(
                name: friendlyName,
                tunnelID: tunnelIDFromConfig.isEmpty ? unit : tunnelIDFromConfig,
                configPath: configPath,
                systemdUnit: unit,
                routes: routes
            ))
        }
        return results
    }

    /// Pulls the path after `--config` out of a raw `ExecStart=...` systemd line.
    private func extractConfigPath(fromExecStart line: String) -> String? {
        guard let range = line.range(of: "--config") else { return nil }
        let after = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        // Handles both "--config /path/to.yml" and "--config=/path/to.yml".
        let cleaned = after.hasPrefix("=") ? String(after.dropFirst()) : after
        return cleaned.split(separator: " ").first.map(String.init)
    }

    /// Pulls the tunnel UUID out of a config.yml's `tunnel:` line.
    private func extractTunnelID(fromConfig yaml: String) -> String {
        for line in yaml.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("tunnel:") {
                return trimmed.replacingOccurrences(of: "tunnel:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    struct DiscoveredTunnel: Identifiable, Hashable {
        var id: String { systemdUnit ?? tunnelID }
        let name: String
        let tunnelID: String
        let configPath: String
        let systemdUnit: String?
        let routes: [(hostname: String, port: Int?)]

        static func == (lhs: DiscoveredTunnel, rhs: DiscoveredTunnel) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }
}

/// Minimal, purpose-built YAML editor for cloudflared's config.yml ingress list —
/// avoids pulling in a full YAML parsing dependency for a narrow, predictable format.
enum ConfigYAMLBuilder {
    /// Parses hostname -> port pairs out of an ingress list, for importing existing configs.
    static func parseIngress(_ yaml: String) -> [(hostname: String, port: Int?)] {
        guard let ingressRange = yaml.range(of: "ingress:") else { return [] }
        var results: [(String, Int?)] = []
        var currentHost: String?
        for rawLine in yaml[ingressRange.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- hostname:") {
                currentHost = trimmed.replacingOccurrences(of: "- hostname:", with: "").trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("service:"), let host = currentHost {
                let service = trimmed.replacingOccurrences(of: "service:", with: "").trimmingCharacters(in: .whitespaces)
                var port: Int?
                if let colonRange = service.range(of: ":", options: .backwards) {
                    port = Int(service[colonRange.upperBound...])
                }
                results.append((host, port))
                currentHost = nil
            }
        }
        return results
    }
    static func upsertIngress(existingYAML: String, tunnelID: String, credentialsFile: String, hostname: String, localPort: Int) -> String {
        let header = "tunnel: \(tunnelID)\ncredentials-file: \(credentialsFile)\n\ningress:\n"
        var entries: [(String, String)] = []

        // Parse existing ingress hostname -> service lines, preserving other routes.
        if let ingressRange = existingYAML.range(of: "ingress:") {
            let after = existingYAML[ingressRange.upperBound...]
            var currentHost: String?
            for rawLine in after.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(rawLine)
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- hostname:") {
                    currentHost = trimmed.replacingOccurrences(of: "- hostname:", with: "").trimmingCharacters(in: .whitespaces)
                } else if trimmed.hasPrefix("service:"), let host = currentHost {
                    let service = trimmed.replacingOccurrences(of: "service:", with: "").trimmingCharacters(in: .whitespaces)
                    if host != hostname { entries.append((host, service)) }
                    currentHost = nil
                }
            }
        }
        entries.append((hostname, "http://localhost:\(localPort)"))

        var body = ""
        for (host, service) in entries {
            body += "  - hostname: \(host)\n    service: \(service)\n"
        }
        body += "  - service: http_status:404\n"
        return header + body
    }

    static func removeIngress(existingYAML: String, hostname: String) -> String {
        let lines = existingYAML.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var result: [String] = []
        var skipNext = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "- hostname: \(hostname)" { skipNext = true; continue }
            if skipNext && trimmed.hasPrefix("service:") { skipNext = false; continue }
            result.append(line)
        }
        return result.joined(separator: "\n")
    }
}