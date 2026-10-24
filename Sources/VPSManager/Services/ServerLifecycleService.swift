import Foundation

struct VPSHostInfo {
    let distribution: String
    let version: String
    let architecture: String
    let machineID: String
    let rootUsedBytes: UInt64
    let rootFreeBytes: UInt64
    let nonRootUsers: [String]
}

struct VPSMigrationPreflight {
    let source: VPSHostInfo
    let destination: VPSHostInfo

    var estimatedTransferBytes: UInt64 { source.rootUsedBytes }
}

final class ServerLifecycleService {
    static let shared = ServerLifecycleService()

    private let preservedPaths = [
        "dev", "proc", "sys", "run", "tmp", "mnt", "media", "lost+found", "boot",
        "etc/ssh", "root/.ssh", "etc/hosts", "etc/hostname", "etc/machine-id",
        "etc/resolv.conf", "etc/fstab", "etc/netplan", "etc/network",
        "etc/systemd/network", "etc/NetworkManager/system-connections", "etc/cloud",
        "etc/ufw", "etc/firewalld", "etc/nftables.conf", "etc/iptables",
        "lib/modules", "usr/lib/modules", "etc/shadow", "etc/gshadow",
        "etc/systemd/system/ssh.service", "etc/systemd/system/sshd.service",
        "etc/systemd/system/systemd-networkd.service", "etc/systemd/system/NetworkManager.service",
        "etc/systemd/system/networking.service", "etc/systemd/system/systemd-resolved.service",
        "etc/systemd/system/multi-user.target.wants/ssh.service",
        "etc/systemd/system/multi-user.target.wants/sshd.service",
        "etc/systemd/system/sockets.target.wants/ssh.socket",
        "var/lib/cloud", "var/lib/NetworkManager"
    ]

    func preflight(_ group: ServerGroup) async throws -> (rootServer: Server, info: VPSHostInfo) {
        guard let rootServer = group.servers.first(where: { $0.user == "root" }) else {
            throw lifecycleError("Add a root SSH connection for \(group.title) before using whole-server operations.")
        }
        return (rootServer, try await inspect(rootServer))
    }

    func preflightTransfer(source: ServerGroup, destination: ServerGroup) async throws -> VPSMigrationPreflight {
        guard source.id != destination.id else {
            throw lifecycleError("Choose two different host groups for a VPS transfer.")
        }
        let sourceResult = try await preflight(source)
        let destinationResult = try await preflight(destination)
        let sourceInfo = sourceResult.info
        let destinationInfo = destinationResult.info

        guard sourceInfo.distribution == destinationInfo.distribution,
              sourceInfo.version == destinationInfo.version,
              sourceInfo.architecture == destinationInfo.architecture else {
            throw lifecycleError(
                "Transfer requires matching Linux distribution, version, and architecture. " +
                "Source: \(sourceInfo.distribution) \(sourceInfo.version) (\(sourceInfo.architecture)); " +
                "destination: \(destinationInfo.distribution) \(destinationInfo.version) (\(destinationInfo.architecture))."
            )
        }
        guard sourceInfo.machineID != destinationInfo.machineID else {
            throw lifecycleError("The selected source and destination resolve to the same VPS machine identity.")
        }
        guard destinationInfo.rootFreeBytes > sourceInfo.rootUsedBytes else {
            throw lifecycleError("The destination has less free disk space than the source data requires.")
        }
        return VPSMigrationPreflight(source: sourceInfo, destination: destinationInfo)
    }

    func reset(_ server: Server) async throws {
        _ = try await inspect(server)
        let script = """
        set -eu
        test "$(id -u)" = 0

        for unit in $(systemctl list-unit-files --type=service --no-legend 2>/dev/null | awk '$1 ~ /^(cloudflared|pm2-)/ {print $1}'); do
          systemctl disable --now "$unit" >/dev/null 2>&1 || true
          rm -f -- "/etc/systemd/system/$unit"
        done
        for unit in mysql mariadb postgresql redis-server docker nginx apache2 caddy supervisor; do
          systemctl disable --now "$unit" >/dev/null 2>&1 || true
        done
        for unit in $(find /etc/systemd/system -maxdepth 1 -type f \\( -name '*.service' -o -name '*.timer' -o -name '*.socket' \\) \\
          ! -name 'ssh.service' ! -name 'sshd.service' \\
          ! -name 'systemd-networkd.service' ! -name 'NetworkManager.service' \\
          ! -name 'networking.service' ! -name 'systemd-resolved.service' \\
          ! -name 'cloud-init.service' ! -name 'cloud-init-local.service' -printf '%f\\n'); do
          systemctl disable --now "$unit" >/dev/null 2>&1 || true
          rm -f -- "/etc/systemd/system/$unit"
        done
        systemctl daemon-reload

        for account in $(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "root" && $1 != "nobody" {print $1}'); do
          pkill -KILL -u "$account" >/dev/null 2>&1 || true
          userdel -r "$account"
        done

        find /root -mindepth 1 -maxdepth 1 ! -name .ssh -exec rm -rf -- {} +
        for path in /home /var/www /opt /srv /usr/local /etc/cloudflared \\
                    /etc/caddy /var/lib/docker /var/lib/mysql /var/lib/mariadb \\
                    /var/lib/postgresql /var/lib/redis /var/lib/mongodb /var/lib/rabbitmq \\
                    /var/lib/elasticsearch /var/log/nginx /var/log/apache2 /var/log/mysql \\
                    /var/log/postgresql; do
          if [ -e "$path" ]; then rm -rf -- "$path"; fi
        done
        for path in /etc/nginx/sites-available /etc/nginx/sites-enabled \\
                    /etc/nginx/conf.d /etc/apache2/sites-available \\
                    /etc/apache2/sites-enabled /etc/apache2/conf-enabled \\
                    /etc/supervisor/conf.d; do
          if [ -d "$path" ]; then find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; fi
        done
        mkdir -p /root/.ssh
        chown root:root /root/.ssh
        chmod 700 /root/.ssh
        if [ -e /root/.ssh/authorized_keys ]; then chmod 600 /root/.ssh/authorized_keys; fi
        if [ -e /root/.ssh/authorized_keys2 ]; then chmod 600 /root/.ssh/authorized_keys2; fi
        """
        try await runRootScript(server, script)
    }

    func transfer(
        source: Server,
        destination: Server,
        passphrase: String,
        appPayload: Data,
        progress: @escaping (String) -> Void
    ) async throws -> Data {
        guard source.user == "root", destination.user == "root" else {
            throw lifecycleError("Whole-VPS transfer requires direct root SSH connections for both hosts.")
        }
        guard source.hostGroupKey != destination.hostGroupKey else {
            throw lifecycleError("Source and destination must be different VPS host groups.")
        }

        progress("Checking OS, architecture, root access, and disk capacity…\n")
        let sourceInfo = try await inspect(source)
        let destinationInfo = try await inspect(destination)
        guard sourceInfo.distribution == destinationInfo.distribution,
              sourceInfo.version == destinationInfo.version,
              sourceInfo.architecture == destinationInfo.architecture else {
            throw lifecycleError("The source and destination OS versions or architectures do not match.")
        }
        guard sourceInfo.machineID != destinationInfo.machineID else {
            throw lifecycleError("The selected source and destination resolve to the same VPS machine identity.")
        }
        guard destinationInfo.rootFreeBytes > sourceInfo.rootUsedBytes else {
            throw lifecycleError("The destination does not have enough free disk space.")
        }

        progress("Encrypting app settings and PM2 environment values locally…\n")
        let encryptedPayload = try TransferEncryption.encrypt(appPayload, passphrase: passphrase)

        progress("Resetting destination user/application data while retaining its root SSH and network identity…\n")
        try await reset(destination)

        progress("Streaming source system files to the destination…\n")
        try await streamSystem(source: source, destination: destination)
        progress("Restoring source account credentials while retaining destination root authentication…\n")
        try await restoreSourceAccounts(source: source, destination: destination)

        progress("Requesting destination reboot and checking SSH recovery…\n")
        let previousUptime = try await readUptime(destination)
        try await ServerControlService.shared.restart(destination)
        try await waitForRootSSH(destination, previousUptime: previousUptime)

        progress("Destination rebooted and root SSH access verified.\n")
        return try TransferEncryption.decrypt(encryptedPayload, passphrase: passphrase)
    }

    private func inspect(_ server: Server) async throws -> VPSHostInfo {
        guard server.user == "root" else {
            throw lifecycleError("Whole-server actions require a saved root SSH connection for \(server.host):\(server.port).")
        }
        let command = """
        set -eu
        test "$(id -u)" = 0
        test -s /root/.ssh/authorized_keys || test -s /root/.ssh/authorized_keys2
        sshd -t
        . /etc/os-release
        printf 'ID=%s\\nVERSION_ID=%s\\nARCH=%s\\nMACHINE_ID=%s\\n' "$ID" "$VERSION_ID" "$(uname -m)" "$(cat /etc/machine-id)"
        df -PB1 / | awk 'NR == 2 {print "ROOT_FREE=" $4}'
        du -sx --block-size=1 / 2>/dev/null | awk '{print "ROOT_USED=" $1}'
        getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "root" && $1 != "nobody" {print "USER=" $1}'
        """
        let output: String
        do {
            output = try await ShellService.shared.sshExpectingSuccess(server, command: command, timeout: 600)
        } catch {
            throw lifecycleError("Root preflight failed for \(server.host): \(error.localizedDescription)")
        }
        var values: [String: String] = [:]
        var users: [String] = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            if text.hasPrefix("USER=") {
                users.append(String(text.dropFirst(5)))
            } else if let separator = text.firstIndex(of: "=") {
                values[String(text[..<separator])] = String(text[text.index(after: separator)...])
            }
        }
        guard let distro = values["ID"], let version = values["VERSION_ID"],
              let architecture = values["ARCH"],
              let machineID = values["MACHINE_ID"], !machineID.isEmpty,
              let used = values["ROOT_USED"].flatMap(UInt64.init),
              let free = values["ROOT_FREE"].flatMap(UInt64.init) else {
            throw lifecycleError("Could not read the Linux release and disk details from \(server.host).")
        }
        return VPSHostInfo(
            distribution: distro,
            version: version,
            architecture: architecture,
            machineID: machineID,
            rootUsedBytes: used,
            rootFreeBytes: free,
            nonRootUsers: users.sorted()
        )
    }

    private func runRootScript(_ server: Server, _ script: String) async throws {
        let encoded = Data(script.utf8).base64EncodedString()
        let command = "printf '%s' '\(encoded)' | base64 -d | bash"
        let result = try await ShellService.shared.ssh(server, command: command, timeout: 3600)
        guard result.success else {
            let details = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "No output was returned."
            throw lifecycleError("Whole-server reset failed (exit code \(result.exitCode)): \(details)")
        }
    }

    private func streamSystem(source: Server, destination: Server) async throws {
        var sourceArgs = source.sshArgs
        var destinationArgs = destination.sshArgs

        let tarArgs = ["tar", "--create", "--file=-", "--numeric-owner", "--acls", "--xattrs", "--xattrs-include=*", "--one-file-system", "--directory=/"]
            + preservedPaths.map { "--exclude=./\($0)" }
            + ["."]
        let sourceCommand = tarArgs.map(shellQuote).joined(separator: " ")
        let destinationCommand = "tar --extract --file=- --numeric-owner --same-owner --same-permissions --acls --xattrs --directory=/"

        guard let sourceTarget = sourceArgs.popLast(), let destinationTarget = destinationArgs.popLast() else {
            throw lifecycleError("Could not prepare SSH commands for the VPS transfer.")
        }
        sourceArgs += [sourceTarget, sourceCommand]
        destinationArgs += [destinationTarget, destinationCommand]

        let transferPipe = Pipe()
        let sourceErrors = Pipe()
        let destinationErrors = Pipe()
        let sourceErrorBuffer = PipeBuffer()
        let destinationErrorBuffer = PipeBuffer()
        let sourceProcess = Process()
        let destinationProcess = Process()

        sourceProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        sourceProcess.arguments = sourceArgs
        sourceProcess.standardOutput = transferPipe
        sourceProcess.standardError = sourceErrors
        destinationProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        destinationProcess.arguments = destinationArgs
        destinationProcess.standardInput = transferPipe
        destinationProcess.standardError = destinationErrors

        sourceErrors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { sourceErrorBuffer.append(data) }
        }
        destinationErrors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { destinationErrorBuffer.append(data) }
        }

        do {
            try destinationProcess.run()
            try sourceProcess.run()
        } catch {
            if destinationProcess.isRunning { destinationProcess.terminate() }
            if sourceProcess.isRunning { sourceProcess.terminate() }
            throw lifecycleError("Could not start the SSH transfer: \(error.localizedDescription)")
        }
        transferPipe.fileHandleForWriting.closeFile()
        transferPipe.fileHandleForReading.closeFile()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                sourceProcess.waitUntilExit()
                destinationProcess.waitUntilExit()
                continuation.resume()
            }
        }

        sourceErrors.fileHandleForReading.readabilityHandler = nil
        destinationErrors.fileHandleForReading.readabilityHandler = nil
        guard sourceProcess.terminationStatus == 0, destinationProcess.terminationStatus == 0 else {
            let sourceOutput = String(data: sourceErrorBuffer.snapshot(), encoding: .utf8) ?? ""
            let destinationOutput = String(data: destinationErrorBuffer.snapshot(), encoding: .utf8) ?? ""
            let detail = [sourceOutput, destinationOutput]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw lifecycleError(
                "System file transfer failed (source exit \(sourceProcess.terminationStatus), " +
                "destination exit \(destinationProcess.terminationStatus)). " +
                (detail.isEmpty ? "No SSH/tar diagnostic was returned." : detail)
            )
        }
    }

    private func restoreSourceAccounts(source: Server, destination: Server) async throws {
        let output = try await ShellService.shared.sshExpectingSuccess(
            source,
            command: "awk -F: '$1 != \"root\" {print}' /etc/shadow",
            timeout: 60
        )
        let accountLines = output.split(separator: "\n").filter { line in
            let fields = line.split(separator: ":", omittingEmptySubsequences: false)
            return fields.count == 9 && fields[0] != "root"
        }
        let encoded = Data(accountLines.joined(separator: "\n").utf8).base64EncodedString()
        let script = """
        set -eu
        source_file=$(mktemp)
        merged_file=$(mktemp /etc/shadow.vpsmgr.XXXXXX)
        trap 'rm -f -- "$source_file" "$merged_file"' EXIT
        printf '%s' '\(encoded)' | base64 -d > "$source_file"
        awk -F: '
          NR == FNR { if ($1 != "root") source[$1] = $0; next }
          $1 == "root" { print; next }
          $1 in source { print source[$1]; delete source[$1]; next }
          END { for (user in source) print source[user] }
        ' "$source_file" /etc/shadow > "$merged_file"
        chown --reference=/etc/shadow "$merged_file"
        chmod --reference=/etc/shadow "$merged_file"
        mv -f -- "$merged_file" /etc/shadow
        """
        try await runRootScript(destination, script)
    }

    private func readUptime(_ server: Server) async throws -> Double {
        let output = try await ShellService.shared.sshExpectingSuccess(
            server,
            command: "awk '{print $1}' /proc/uptime"
        )
        guard let uptime = output.split(whereSeparator: \.isNewline).last.flatMap(Double.init) else {
            throw lifecycleError("Could not read destination uptime before reboot.")
        }
        return uptime
    }

    private func waitForRootSSH(_ server: Server, previousUptime: Double) async throws {
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(5))
            if let output = try? await ShellService.shared.ssh(server, command: "awk '{print $1}' /proc/uptime", timeout: 10),
               output.success,
               let uptime = output.stdout.split(whereSeparator: \.isNewline).last.flatMap(Double.init),
               uptime < previousUptime {
                return
            }
        }
        throw lifecycleError(
            "The destination did not return on root SSH after the transfer. Its destination SSH keys and network identity were preserved; use your provider's console/rescue access to recover it."
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func lifecycleError(_ message: String) -> NSError {
        NSError(domain: "ServerLifecycleService", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
