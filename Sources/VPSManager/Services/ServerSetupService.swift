import Foundation

/// Drives the interactive setup flows: a fresh VPS (root + password → key-based
/// root login, optional new root password and sudo user), an existing account on
/// a physical PC, and enabling key-only root login on an already-set-up server.
@MainActor
final class ServerSetupService: ObservableObject {
    @Published var log: String = ""
    @Published var isRunning = false
    @Published var currentStepIndex = 0
    @Published var awaitingPassword = false
    @Published var finished = false
    @Published var error: String?

    @Published var steps: [String] = []

    private var pty: PTYProcess?
    private var passwordContinuation: CheckedContinuation<String, Never>?

    struct Input {
        var host: String
        var port: Int = 22
        var rootPassword: String
        /// nil keeps the current root password.
        var newRootPassword: String?
        /// nil skips creating an extra sudo account.
        var sudoUsername: String?
        /// Key-only SSH (recommended). When false, password logins stay on.
        var disablePasswordLogin = true
        var keyName: String = "id_ed25519"
    }

    struct PhysicalPCInput {
        var host: String
        var port: Int
        var username: String
        var accountPassword: String
    }

    func provide(password: String) {
        awaitingPassword = false
        passwordContinuation?.resume(returning: password)
        passwordContinuation = nil
    }

    /// Sets up a fresh VPS around **root**: installs this Mac's key for root,
    /// optionally changes the root password and adds a sudo user, and switches
    /// SSH to key-only root login (`PermitRootLogin prohibit-password`). Root
    /// stays the account the app uses, which is what whole-server operations
    /// (Reset, Transfer) need.
    ///
    /// Returns the servers to add: root first, then the sudo user if one was made.
    func run(_ input: Input) async -> [Server] {
        isRunning = true
        error = nil
        finished = false
        log = ""
        var plan = [
            "Generate local SSH keypair (if needed)",
            "Connect as root with the password",
            "Install your key for root",
        ]
        if input.newRootPassword != nil { plan.append("Set the new root password") }
        if input.sudoUsername != nil { plan.append("Create sudo user \(input.sudoUsername!)") }
        plan.append(input.disablePasswordLogin ? "Switch SSH to key-only login" : "Allow root login with key or password")
        plan.append("Verify key login as root")
        steps = plan
        currentStepIndex = 0
        defer { isRunning = false }

        func advance(_ message: String) {
            currentStepIndex += 1
            append(message + "\n")
        }

        let host = input.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPath = "~/.ssh/\(input.keyName)"
        let expandedKeyPath = (keyPath as NSString).expandingTildeInPath
        // One password-authenticated master connection, reused by every root
        // step, so the password is typed once instead of once per command.
        let controlPath = Server.controlSocketDirectory + "/setup-%C"
        let rootSSH = [
            "-p", "\(input.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlPath)",
            "-o", "ControlPersist=120",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "PubkeyAuthentication=no",
            "root@\(host)",
        ]
        defer {
            Task { _ = try? await ShellService.shared.run("ssh", ["-o", "ControlPath=\(controlPath)", "-O", "exit", "root@\(host)"], timeout: 5) }
        }
        func asRoot(_ script: String) async throws {
            try await runInteractive(exe: "ssh", args: rootSSH + ["sh -c \(shellQuoted(script))"], password: input.rootPassword)
        }

        do {
            // 1. Local keypair
            if !FileManager.default.fileExists(atPath: expandedKeyPath) {
                append("Generating new ed25519 keypair at \(keyPath)...\n")
                let r = try await ShellService.shared.run("ssh-keygen", ["-t", "ed25519", "-f", expandedKeyPath, "-N", ""])
                guard r.success else { throw SetupError.generic(r.stderr) }
            } else {
                append("Found existing key at \(keyPath), reusing it.\n")
            }
            let pubKey = try String(contentsOfFile: expandedKeyPath + ".pub", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let keyB64 = Data(pubKey.utf8).base64EncodedString()

            // 2. Root password login
            advance("Connecting as root@\(host):\(input.port)...")
            try await runInteractive(exe: "ssh", args: rootSSH + ["echo CONNECTED_OK"], password: input.rootPassword)

            // 3. Key for root
            advance("Installing your public key for root...")
            try await asRoot("""
            set -e
            install -d -m 700 /root/.ssh
            touch /root/.ssh/authorized_keys
            key=$(printf '%s' '\(keyB64)' | base64 -d)
            grep -qxF "$key" /root/.ssh/authorized_keys || printf '%s\\n' "$key" >> /root/.ssh/authorized_keys
            chmod 600 /root/.ssh/authorized_keys
            """)

            // 4. Optional new root password
            if let newPassword = input.newRootPassword {
                advance("Setting the new root password...")
                let pair = Data("root:\(newPassword)".utf8).base64EncodedString()
                try await asRoot("printf '%s' '\(pair)' | base64 -d | chpasswd")
            }

            // 5. Optional sudo user
            if let username = input.sudoUsername {
                advance("Creating sudo user \(username)...")
                let user = shellQuoted(username)
                try await asRoot("""
                set -e
                id -u \(user) >/dev/null 2>&1 || useradd -m -s /bin/bash \(user)
                usermod -aG sudo \(user) 2>/dev/null || usermod -aG wheel \(user) 2>/dev/null || true
                home=$(getent passwd \(user) | cut -d: -f6)
                install -d -m 700 -o \(user) "$home/.ssh"
                touch "$home/.ssh/authorized_keys"
                key=$(printf '%s' '\(keyB64)' | base64 -d)
                grep -qxF "$key" "$home/.ssh/authorized_keys" || printf '%s\\n' "$key" >> "$home/.ssh/authorized_keys"
                chmod 600 "$home/.ssh/authorized_keys"
                chown \(user) "$home/.ssh/authorized_keys"
                printf '%s ALL=(ALL) NOPASSWD:ALL\\n' \(user) > /etc/sudoers.d/\(user)
                chmod 440 /etc/sudoers.d/\(user)
                """)
            }

            // 6. sshd settings, validated before restarting
            advance(input.disablePasswordLogin
                    ? "Switching SSH to key-only login (root keeps key access)..."
                    : "Allowing root login with key or password...")
            try await asRoot(Self.sshdScript(keyOnly: input.disablePasswordLogin))

            // 7. Verify
            advance("Verifying key login as root@\(host)...")
            try await verifyKeyLogin(user: "root", host: host, port: input.port, key: expandedKeyPath)
            var servers = [Server(nickname: host, host: host, port: input.port, user: "root",
                                  identityFile: keyPath, isHardened: input.disablePasswordLogin)]
            if let username = input.sudoUsername {
                try await verifyKeyLogin(user: username, host: host, port: input.port, key: expandedKeyPath)
                servers.append(Server(nickname: "\(host) (\(username))", host: host, port: input.port, user: username,
                                      identityFile: keyPath, isHardened: input.disablePasswordLogin))
            }
            append("✅ Key login confirmed. Setup complete.\n")
            currentStepIndex = steps.count
            finished = true
            return servers
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            append("❌ \(self.error!)\n")
            return []
        }
    }

    /// Turns on key-only root login on an already-set-up server, through a saved
    /// account with passwordless sudo: copies that account's authorized keys to
    /// root and sets `PermitRootLogin prohibit-password` (password login is left
    /// as it is). Returns the new root server entry once key login is verified.
    static func enableRootLogin(via server: Server) async throws -> Server {
        let script = """
        set -e
        install -d -m 700 /root/.ssh
        touch /root/.ssh/authorized_keys
        while IFS= read -r key; do
          [ -n "$key" ] || continue
          grep -qxF "$key" /root/.ssh/authorized_keys || printf '%s\\n' "$key" >> /root/.ssh/authorized_keys
        done < "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
        chmod 600 /root/.ssh/authorized_keys
        """ + "\n" + sshdScript(keyOnly: nil)
        let command = "sudo -n sh -c \(shellQuotedStatic(script))"
        try await ShellService.shared.sshExpectingSuccess(server, command: command, timeout: 60)
        var root = server
        root.id = UUID()
        root.user = "root"
        root.nickname = server.host
        root.createdAt = Date()
        let check = try await ShellService.shared.run("ssh", ["-p", "\(server.port)", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                                              "-o", "StrictHostKeyChecking=accept-new"]
                                                      + (server.identityFile.isEmpty ? [] : ["-i", (server.identityFile as NSString).expandingTildeInPath])
                                                      + ["root@\(server.host)", "echo ROOT_OK"], timeout: 20)
        guard check.success, check.stdout.contains("ROOT_OK") else {
            throw SetupError.generic("Root login was enabled, but logging in as root with your key failed: \(check.stderr)")
        }
        return root
    }

    /// Writes VPS Manager's sshd settings — as a drop-in that wins over
    /// cloud-init's when the distro supports sshd_config.d, otherwise in
    /// sshd_config itself — checks them with `sshd -t`, rolls back if invalid,
    /// and reloads sshd. `keyOnly == nil` only changes PermitRootLogin.
    private static func sshdScript(keyOnly: Bool?) -> String {
        var settings = ["PermitRootLogin \(keyOnly == false ? "yes" : "prohibit-password")", "PubkeyAuthentication yes"]
        if keyOnly == true {
            settings += ["PasswordAuthentication no", "KbdInteractiveAuthentication no"]
        } else if keyOnly == false {
            settings += ["PasswordAuthentication yes"]
        }
        let keys = settings.map { String($0.split(separator: " ")[0]) }
        let lines = settings.joined(separator: "\\n")
        return """
        set -e
        conf=/etc/ssh/sshd_config
        backup="$conf.bak.vpsmanager.$(date +%s)"
        cp "$conf" "$backup"
        dropin=""
        if [ -d /etc/ssh/sshd_config.d ] && grep -qiE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d' "$conf"; then
          dropin=/etc/ssh/sshd_config.d/00-vpsmanager.conf
          printf '# Managed by VPS Manager\\n\(lines)\\n' > "$dropin"
        else
          for key in \(keys.joined(separator: " ")); do sed -i "s/^#\\{0,1\\}[[:space:]]*$key[[:space:]].*//" "$conf"; done
          printf '\\n# Managed by VPS Manager\\n\(lines)\\n' >> "$conf"
        fi
        sshd_bin=$(command -v sshd || echo /usr/sbin/sshd)
        if ! "$sshd_bin" -t; then
          cp "$backup" "$conf"
          [ -n "$dropin" ] && rm -f "$dropin"
          echo "sshd rejected the new settings; restored the previous configuration." >&2
          exit 1
        fi
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || service ssh restart
        """
    }

    private func verifyKeyLogin(user: String, host: String, port: Int, key: String) async throws {
        let verify = try await ShellService.shared.run("ssh", [
            "-p", "\(port)", "-i", key, "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=10",
            "\(user)@\(host)", "echo PASSWORDLESS_OK"
        ])
        guard verify.success, verify.stdout.contains("PASSWORDLESS_OK") else {
            throw SetupError.generic("Could not verify key login as \(user): \(verify.stderr)")
        }
    }

    private static func shellQuotedStatic(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    func runPhysicalPC(_ input: PhysicalPCInput) async -> Server? {
        isRunning = true
        error = nil
        finished = false
        log = ""
        steps = [
            "Generate a dedicated local SSH keypair",
            "Connect to the PC as the existing user & verify",
            "Install the public key with sudo",
            "Verify passwordless login as that user"
        ]
        defer { isRunning = false }

        guard (1...65535).contains(input.port) else {
            error = "Port must be between 1 and 65535."
            return nil
        }
        guard input.username.range(of: #"^[a-z_][a-z0-9_-]*\$?$"#, options: .regularExpression) != nil else {
            error = "Enter a valid Linux username."
            return nil
        }

        let keyPath = "~/.ssh/id_ed25519_vpsmanager"
        let expandedKeyPath = (keyPath as NSString).expandingTildeInPath
        let publicKeyPath = expandedKeyPath + ".pub"
        let sshBaseArgs = [
            "-p", "\(input.port)",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=8"
        ]

        do {
            currentStepIndex = 0
            let hasPrivateKey = FileManager.default.fileExists(atPath: expandedKeyPath)
            let hasPublicKey = FileManager.default.fileExists(atPath: publicKeyPath)
            if !hasPrivateKey && !hasPublicKey {
                append("Generating a dedicated ed25519 keypair at \(keyPath)...\n")
                let result = try await ShellService.shared.run("ssh-keygen", [
                    "-t", "ed25519", "-f", expandedKeyPath, "-N", ""
                ])
                guard result.success else { throw SetupError.generic(result.stderr) }
                append(result.stdout)
            } else if !hasPrivateKey || !hasPublicKey {
                throw SetupError.generic("The dedicated SSH key is incomplete. Restore or remove both \(keyPath) and \(keyPath).pub before retrying.")
            } else {
                append("Reusing the existing dedicated keypair at \(keyPath).\n")
            }

            currentStepIndex = 1
            append("Connecting as \(input.username)@\(input.host):\(input.port) to verify the account password...\n")
            try await runInteractive(
                exe: "ssh",
                args: sshBaseArgs + [
                    "-o", "PreferredAuthentications=password",
                    "-o", "PubkeyAuthentication=no",
                    "\(input.username)@\(input.host)",
                    "echo CONNECTED_OK"
                ],
                password: input.accountPassword
            )

            currentStepIndex = 2
            let publicKey = try String(contentsOfFile: publicKeyPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !publicKey.isEmpty else {
                throw SetupError.generic("The generated public key file is empty.")
            }
            let publicKeyBase64 = Data(publicKey.utf8).base64EncodedString()
            let quotedUsername = shellQuoted(input.username)
            let installKeyScript = """
            set -eu
            entry=$(getent passwd \(quotedUsername)) || { echo "User \(input.username) does not exist on this PC." >&2; exit 1; }
            home=$(printf '%s' "$entry" | cut -d: -f6)
            test -n "$home" || { echo "Could not find the home directory for \(input.username)." >&2; exit 1; }
            install -d -m 700 -o \(quotedUsername) "$home/.ssh"
            auth="$home/.ssh/authorized_keys"
            touch "$auth"
            key=$(printf '%s' '\(publicKeyBase64)' | base64 -d)
            grep -qxF "$key" "$auth" || printf '%s\\n' "$key" >> "$auth"
            chmod 600 "$auth"
            chown \(quotedUsername) "$auth"
            """
            let installKeyCommand = "sudo -S -p '[sudo] password: ' sh -c \(shellQuoted(installKeyScript))"
            append("Installing the public key for existing user \(input.username)...\n")
            try await runInteractive(
                exe: "ssh",
                args: sshBaseArgs + ["\(input.username)@\(input.host)", installKeyCommand],
                password: input.accountPassword,
                passwordPromptLimit: 2
            )

            currentStepIndex = 3
            append("Verifying passwordless login as \(input.username)@\(input.host)...\n")
            let verify = try await ShellService.shared.run("ssh", sshBaseArgs + [
                "-i", expandedKeyPath,
                "-o", "BatchMode=yes",
                "\(input.username)@\(input.host)",
                "echo PASSWORDLESS_OK"
            ])
            guard verify.success, verify.stdout.contains("PASSWORDLESS_OK") else {
                throw SetupError.generic("Could not verify passwordless login: \(verify.stderr)")
            }

            append("Passwordless SSH confirmed. The existing user and SSH settings were left unchanged.\n")
            finished = true
            return Server(
                nickname: input.host,
                host: input.host,
                port: input.port,
                user: input.username,
                identityFile: keyPath,
                isHardened: false
            )
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            append("Setup failed: \(self.error!)\n")
            return nil
        }
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Runs a command over an interactive PTY, watches for a password prompt, and
    /// resolves it by asking the UI (via awaitingPassword) or reusing a cached one.
    private func runInteractive(
        exe: String,
        args: [String],
        password: String,
        passwordPromptLimit: Int = 1
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let proc = PTYProcess()
            var passwordPromptsSent = 0
            proc.onOutput = { [weak self] chunk in
                guard let self else { return }
                self.append(chunk)
                let lower = chunk.lowercased()
                if passwordPromptsSent < passwordPromptLimit &&
                    (lower.contains("password:") || lower.contains("password for")) {
                    passwordPromptsSent += 1
                    proc.send(password + "\n")
                }
                if lower.contains("connection refused") || lower.contains("permission denied") {
                    // let it finish; exit code / termination handler will surface the error
                }
            }
            proc.onExit = { code in
                if code == 0 {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: SetupError.generic("Command exited with code \(code)"))
                }
            }
            self.pty = proc
            _ = proc.start(executable: exe, arguments: args, environment: ProcessInfo.processInfo.environment)
        }
    }

    private func append(_ s: String) {
        log += s
    }

    enum SetupError: LocalizedError {
        case generic(String)
        var errorDescription: String? {
            switch self { case .generic(let s): return s }
        }
    }
}
