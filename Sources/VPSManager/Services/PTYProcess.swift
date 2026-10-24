import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Spawns a process attached to a real pseudo-terminal, so tools like `ssh` and
/// `ssh-copy-id` behave exactly as they would in Terminal.app (password prompts,
/// host key prompts, ANSI output, etc). Used by both the interactive Setup Wizard
/// and the embedded Terminal tab.
final class PTYProcess {
    private(set) var masterFD: Int32 = -1
    private var childPID: pid_t = -1
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    private var readSource: DispatchSourceRead?

    @discardableResult
    func start(executable: String, arguments: [String], environment: [String: String]) -> Bool {
        var winSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &winSize)

        if pid == 0 {
            // Child process: exec the target binary.
            var envStrings = environment.map { "\($0.key)=\($0.value)" }
            envStrings.append("TERM=xterm-256color")
            let envPointers: [UnsafeMutablePointer<CChar>?] = envStrings.map { strdup($0) } + [nil]

            let fullPath = "/usr/bin/env"
            let args = [fullPath, executable] + arguments
            let argPointers: [UnsafeMutablePointer<CChar>?] = args.map { strdup($0) } + [nil]

            execve(fullPath, argPointers, envPointers)
            _exit(127)
        } else if pid > 0 {
            self.childPID = pid
            self.masterFD = master
            beginReading()
            return true
        }
        return false
    }

    private func beginReading() {
        let src = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: .global(qos: .userInitiated))
        src.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let n = read(self.masterFD, &buffer, buffer.count)
            if n > 0 {
                let str = String(decoding: buffer[0..<n], as: UTF8.self)
                DispatchQueue.main.async { self.onOutput?(str) }
            } else if n <= 0 {
                src.cancel()
            }
        }
        src.setCancelHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(self.childPID, &status, 0)
            DispatchQueue.main.async { self.onExit?(status) }
        }
        readSource = src
        src.resume()
    }

    func send(_ text: String) {
        guard masterFD >= 0 else { return }
        let data = Array(text.utf8)
        data.withUnsafeBufferPointer { ptr in
            _ = write(masterFD, ptr.baseAddress, ptr.count)
        }
    }

    func resize(cols: Int32, rows: Int32) {
        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func terminate() {
        if childPID > 0 { kill(childPID, SIGTERM) }
        readSource?.cancel()
        if masterFD >= 0 { close(masterFD) }
    }
}