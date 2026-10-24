import Foundation

final class SystemdService {
    static let shared = SystemdService()

    /// Common units the app tracks out of the box for a newly added server.
    let defaultUnits = ["cloudflared", "nginx", "sshd", "ssh", "docker", "postgresql", "redis-server"]

    /// Low-level OS units that aren't useful to pre-select when discovering "your
    /// app's services" — still fully visible/selectable in the discovery picker,
    /// just not pre-checked, so custom services like echo-api aren't buried under
    /// dozens of systemd internals.
    static let noisePrefixes = [
        "systemd-", "dbus", "getty@", "user@", "session-", "cron", "rsyslog", "polkit",
        "networkd-dispatcher", "ModemManager", "snapd", "apparmor", "accounts-daemon",
        "packagekit", "udisks2", "upower", "unattended-upgrades", "e2scrub", "fstrim",
        "logrotate", "man-db", "motd-news", "apt-daily", "systemd-", "ssh-agent",
        "console-setup", "keyboard-setup", "grub-", "plymouth", "ufw", "irqbalance"
    ]

    func status(_ server: Server, unit: String) async throws -> SystemdUnitStatus {
        let cmd = "systemctl show \(unit) --property=ActiveState,SubState,UnitFileState --no-pager 2>/dev/null"
        let output = try await ShellService.shared.ssh(server, command: cmd)
        var active = "unknown", sub = "unknown", fileState = "unknown"
        for line in output.stdout.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "ActiveState": active = String(parts[1])
            case "SubState": sub = String(parts[1])
            case "UnitFileState": fileState = String(parts[1])
            default: break
            }
        }
        return SystemdUnitStatus(name: unit, activeState: active, subState: sub, enabled: fileState == "enabled")
    }

    /// Fetches status for every requested unit in ONE ssh call instead of 2 per unit
    /// (a previous existence-check call plus a status call each) — much faster once
    /// you're tracking more than a couple of services.
    ///
    /// Requested names may or may not include a suffix ("nginx" vs
    /// "echo-consolidation.timer") — `systemctl show` defaults a bare name to
    /// `.service`, which is fine for services but silently resolves to nothing for
    /// a timer-only unit. So bare names get `.service` appended explicitly here
    /// rather than relying on systemd's own default, and anything with an explicit
    /// suffix is passed through untouched.
    func statuses(_ server: Server, units: [String]) async throws -> [SystemdUnitStatus] {
        guard !units.isEmpty else { return [] }
        let canonical = units.map { canonicalUnitName($0) }
        let unitList = canonical.joined(separator: " ")
        let cmd = "systemctl show \(unitList) --property=Id,LoadState,ActiveState,SubState,UnitFileState --no-pager 2>/dev/null"
        let output = (try? await ShellService.shared.ssh(server, command: cmd))?.stdout ?? ""

        var results: [String: SystemdUnitStatus] = [:] // keyed by full "name.service"/"name.timer"
        for block in output.components(separatedBy: "\n\n") {
            var id = "", loadState = "", active = "unknown", sub = "unknown", fileState = "unknown"
            for line in block.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "Id": id = String(parts[1])
                case "LoadState": loadState = String(parts[1])
                case "ActiveState": active = String(parts[1])
                case "SubState": sub = String(parts[1])
                case "UnitFileState": fileState = String(parts[1])
                default: break
                }
            }
            guard !id.isEmpty, loadState != "not-found" else { continue }
            // Keep the suffix in .name — that's what distinguishes a timer from its
            // same-named service, and it's what every control action below needs to
            // target the right one. Display-layer code strips ".service" for
            // cosmetics but keeps ".timer" visible.
            results[id] = SystemdUnitStatus(name: id, activeState: active, subState: sub, enabled: fileState == "enabled")
        }
        // Preserve the order the caller asked for, dropping any that don't exist.
        return canonical.compactMap { results[$0] }
    }

    /// `systemctl` treats a bare name as `.service` by default — make that explicit
    /// instead of relying on it, since it's the exact thing that was hiding timers.
    private func canonicalUnitName(_ requested: String) -> String {
        requested.contains(".") ? requested : requested + ".service"
    }

    /// Includes both .service and .timer units, since real deployments commonly use
    /// timers for scheduled jobs (e.g. echo-consolidation.timer). Suffixes are kept
    /// intact so a service and its same-named timer show up as two distinct,
    /// individually trackable entries rather than colliding into one.
    func discoverAllUnits(_ server: Server) async throws -> [String] {
        let cmd = """
        systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '{print $1}'
        systemctl list-unit-files --type=timer --no-legend 2>/dev/null | awk '{print $1}'
        """
        let output = try await ShellService.shared.ssh(server, command: cmd)
        return Array(Set(output.stdout.split(separator: "\n").map(String.init))).sorted()
    }

    func start(_ server: Server, unit: String) async throws { try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n systemctl start \(unit)") }
    func stop(_ server: Server, unit: String) async throws { try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n systemctl stop \(unit)") }
    func restart(_ server: Server, unit: String) async throws { try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n systemctl restart \(unit)") }
    func enable(_ server: Server, unit: String) async throws { try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n systemctl enable \(unit)") }
    func disable(_ server: Server, unit: String) async throws { try await ShellService.shared.sshExpectingSuccess(server, command: "sudo -n systemctl disable \(unit)") }

    func journalTail(_ server: Server, unit: String, lines: Int = 200) async throws -> String {
        try await ShellService.shared.sshExpectingSuccess(server, command: "journalctl -u \(unit) -n \(lines) --no-pager 2>/dev/null")
    }
}