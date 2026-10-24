import Foundation

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var success: Bool { exitCode == 0 }
}

enum ShellError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(ShellResult)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let msg): return "Failed to launch process: \(msg)"
        case .nonZeroExit(let r): return "Command exited with code \(r.exitCode): \(r.stderr)"
        }
    }
}

/// Thrown by `sshExpectingSuccess` instead of the plain `ShellError.nonZeroExit` so
/// callers (and the UI) get an actually actionable message. The single most common
/// reason a `sudo systemctl ...` action "just does nothing" is that the remote user
/// doesn't have passwordless sudo and this app — being a non-interactive SSH session
/// with no pty — has no way to prompt for a password. Rather than surface a bare
/// "exit code 1" (or, worse, have the caller swallow it entirely), detect that
/// specific shape of failure and hand back the exact one-line fix.
struct SSHCommandFailure: LocalizedError {
    let command: String
    let result: ShellResult
    let sshUser: String

    var isLikelySudoPasswordIssue: Bool {
        guard command.contains("sudo") else { return false }
        let text = (result.stderr + " " + result.stdout).lowercased()
        return text.contains("a password is required")
            || text.contains("no tty present")
            || text.contains("sorry, try again")
            || text.contains("not in the sudoers")
            || (text.contains("sudo") && text.contains("password"))
    }

    private var rawOutput: String {
        let stderrTrimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrTrimmed.isEmpty { return stderrTrimmed }
        let stdoutTrimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdoutTrimmed.isEmpty ? "exit code \(result.exitCode)" : stdoutTrimmed
    }

    var errorDescription: String? {
        if isLikelySudoPasswordIssue {
            return """
            This server is asking for a sudo password. VPS Manager connects over a \
            non-interactive SSH session, so it can never type one in.

            Fix it once — SSH in by hand and run:
            echo '\(sshUser) ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/\(sshUser) && sudo chmod 440 /etc/sudoers.d/\(sshUser)

            (raw error: \(rawOutput))
            """
        }
        if result.exitCode == 127 {
            return "Command not found on \(sshUser)'s remote shell — it may not be installed, or its install path isn't on PATH in a login shell. (\(rawOutput))"
        }
        return rawOutput
    }
}

/// Thread-safe accumulator for output read off a Pipe's readabilityHandler, which fires
/// on an arbitrary background queue. Swift 6's strict concurrency checker flags plain
/// captured `var`s mutated from such closures as unsafe — this wraps them behind a lock
/// so the mutation is properly synchronized instead of just "probably fine in practice."
final class PipeBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

/// Thin wrapper around Process for running ssh / rsync / scp / cloudflared locally.
/// This app deliberately shells out to real system binaries instead of reimplementing
/// SSH/SFTP, so it's 100% compatible with whatever the user already configured manually.
final class ShellService {
    static let shared = ShellService()

    /// Common locations Homebrew/system installs put these binaries.
    private let pathAdditions = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    func run(_ executable: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval = 25) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = pathAdditions + ":" + (env["PATH"] ?? "")
            process.environment = env

            let outPipe = Pipe(); let errPipe = Pipe(); let inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            let outBuffer = PipeBuffer()
            let errBuffer = PipeBuffer()
            outPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { outBuffer.append(d) }
            }
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { errBuffer.append(d) }
            }

            let resumed = LockedFlag()

            // Hard execution timeout: if a remote command hangs (slow network, a shell
            // profile script waiting on input, whatever), kill it instead of leaving the
            // UI spinning forever with no way to fail. Connection-level timeouts (ssh's
            // ConnectTimeout) only cover the TCP handshake, not the command actually running.
            let timeoutWorkItem = DispatchWorkItem {
                if process.isRunning { process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

            process.terminationHandler = { proc in
                timeoutWorkItem.cancel()
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                guard resumed.setIfFirst() else { return }
                let result = ShellResult(
                    exitCode: proc.terminationStatus,
                    stdout: String(data: outBuffer.snapshot(), encoding: .utf8) ?? "",
                    stderr: String(data: errBuffer.snapshot(), encoding: .utf8) ?? ""
                )
                continuation.resume(returning: result)
            }

            do {
                try process.run()
                if let input, let data = input.data(using: .utf8) {
                    inPipe.fileHandleForWriting.write(data)
                }
                inPipe.fileHandleForWriting.closeFile()
            } catch {
                if resumed.setIfFirst() {
                    continuation.resume(throwing: ShellError.launchFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Runs a command over SSH on the given server and returns combined result.
    ///
    /// The command is wrapped in `bash -ilc '...'` (interactive + login) rather than
    /// run bare. A plain `ssh host "cmd"` opens a non-interactive, non-login shell,
    /// which skips .bashrc/.profile — so anything whose PATH is set up there (nvm,
    /// pm2, locally-installed cloudflared, etc.) shows up as "command not found"
    /// (exit 127) even though it works fine when the user SSHes in by hand. Using an
    /// interactive login shell reproduces exactly what a real terminal session sees.
    ///
    /// The catch is that an interactive login shell also runs whatever the user's
    /// profile prints (MOTD-style banners, `neofetch`, nvm notices…) and complains
    /// about job control on stderr, all of which used to end up in parsed output.
    /// So a marker line is printed right before the real command, and everything
    /// up to it is dropped; known shell-startup warnings are filtered from stderr.
    func ssh(_ server: Server, command: String, timeout: TimeInterval = 25) async throws -> ShellResult {
        let marked = "printf '%s\\n' '\(Self.outputMarker)'\n" + command
        let escaped = marked.replacingOccurrences(of: "'", with: "'\\''")
        let wrapped = "bash -ilc '\(escaped)'"
        var result = try await run("ssh", server.sshArgs + [wrapped], timeout: timeout)

        if !result.success && looksLikeStaleConnection(result) {
            // The reused multiplexed connection likely died silently (Mac slept,
            // WiFi dropped briefly) while its control socket file lingered, making
            // every command fail until ControlPersist's 10-minute window expires on
            // its own. Clear the socket and retry once with a fresh connection
            // instead of leaving the app looking broken for that whole window.
            try? FileManager.default.removeItem(atPath: server.controlSocketPath)
            result = try await run("ssh", server.sshArgs + [wrapped], timeout: timeout)
        }
        return Self.cleaned(result)
    }

    static let outputMarker = "__VPSMGR_OUTPUT_BEGINS__"

    private static let shellNoise = [
        "cannot set terminal process group",
        "no job control in this shell",
        "Inappropriate ioctl for device",
    ]

    private static func cleaned(_ result: ShellResult) -> ShellResult {
        var stdout = result.stdout
        if let range = stdout.range(of: outputMarker + "\n") ?? stdout.range(of: outputMarker) {
            stdout = String(stdout[range.upperBound...])
        }
        let stderr = result.stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in !shellNoise.contains { line.contains($0) } }
            .joined(separator: "\n")
        return ShellResult(exitCode: result.exitCode, stdout: stdout, stderr: stderr)
    }

    /// Closes the shared SSH master so the next command starts a fresh session.
    /// This is useful after remote account or sudoers changes that should apply to
    /// a newly authenticated SSH connection.
    func restartConnection(_ server: Server) async {
        let sshArgs = server.sshArgs
        let controlArgs = Array(sshArgs.dropLast()) + ["-O", "exit", sshArgs.last!]
        _ = try? await run("ssh", controlArgs, timeout: 10)
        try? FileManager.default.removeItem(atPath: server.controlSocketPath)
    }

    /// ssh itself exits 255 on connection-level failures (as opposed to the remote
    /// command's own exit code). 143 is what our own timeout's SIGTERM produces.
    /// Both are consistent with "the connection, not the command, is the problem."
    private func looksLikeStaleConnection(_ result: ShellResult) -> Bool {
        result.exitCode == 255 || result.exitCode == 143 ||
        result.stderr.localizedCaseInsensitiveContains("control socket") ||
        result.stderr.localizedCaseInsensitiveContains("connection refused") ||
        result.stderr.localizedCaseInsensitiveContains("broken pipe") ||
        result.stderr.localizedCaseInsensitiveContains("connection closed")
    }

    @discardableResult
    func sshExpectingSuccess(_ server: Server, command: String, timeout: TimeInterval = 25) async throws -> String {
        let r = try await ssh(server, command: command, timeout: timeout)
        guard r.success else { throw SSHCommandFailure(command: command, result: r, sshUser: server.user) }
        return r.stdout
    }
}

/// Guards against a continuation being resumed twice (e.g. terminationHandler firing
/// right as the timeout also fires) — resuming a Swift continuation more than once is
/// a runtime crash, so this makes "first one wins" explicit and thread-safe.
final class LockedFlag: @unchecked Sendable {
    private var flag = false
    private let lock = NSLock()
    func setIfFirst() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}