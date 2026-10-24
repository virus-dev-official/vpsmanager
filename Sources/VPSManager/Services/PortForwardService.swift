import Foundation

/// Runs `ssh -N -L <localPort>:localhost:<remotePort> <server>` in the background so a
/// service that's only bound to localhost *on the VPS* (a dev server, a database admin
/// UI, anything not exposed via Cloudflared) becomes reachable at that same port on the
/// Mac's own localhost — which is what the in-app Browser tab actually needs, since a
/// WKWebView's "localhost" always means the Mac, never the remote box.
///
/// Reuses `Server.sshArgs` for the connection itself (same identity file, ControlMaster
/// settings, etc.), so if a Terminal tab already has a live multiplexed connection open
/// for this server, the forward rides along on that existing connection instead of
/// paying for a second handshake — and tearing the forward down later doesn't touch that
/// shared connection, since this is just one more session on it.
@MainActor
final class PortForwardService: ObservableObject {
    static let shared = PortForwardService()
    private init() {}

    struct ActiveForward: Identifiable, Hashable {
        var id: String { key }
        let key: String
        let serverID: UUID
        let localPort: Int
        let remotePort: Int
    }

    enum ForwardError: LocalizedError {
        case processFailedToStart(String)
        var errorDescription: String? {
            switch self {
            case .processFailedToStart(let reason): return "Couldn't start the forward: \(reason)"
            }
        }
    }

    @Published private(set) var active: [ActiveForward] = []
    private var processes: [String: Process] = [:]

    private func key(serverID: UUID, remotePort: Int) -> String { "\(serverID.uuidString)-\(remotePort)" }

    func forward(for serverID: UUID, remotePort: Int) -> ActiveForward? {
        active.first { $0.serverID == serverID && $0.remotePort == remotePort }
    }

    func forwards(for serverID: UUID) -> [ActiveForward] {
        active.filter { $0.serverID == serverID }
    }

    /// Starts a forward if one isn't already running for this server+port; otherwise just
    /// hands back the existing one. `localPort` defaults to the same number as
    /// `remotePort`, which is what you want almost all the time (browsing to the same
    /// port number you'd hit if you were on the VPS itself).
    @discardableResult
    func start(server: Server, remotePort: Int, localPort: Int? = nil) throws -> ActiveForward {
        let target = localPort ?? remotePort
        let k = key(serverID: server.id, remotePort: remotePort)
        if let existing = active.first(where: { $0.key == k }) { return existing }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ssh", "-N", "-L", "\(target):localhost:\(remotePort)"] + server.sshArgs
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ForwardError.processFailedToStart(error.localizedDescription)
        }

        processes[k] = process
        let entry = ActiveForward(key: k, serverID: server.id, localPort: target, remotePort: remotePort)
        active.append(entry)

        // If ssh exits on its own (auth expired, network drop, remote port never had
        // anything listening so it gave up, etc.) reflect that immediately rather than
        // leaving a dead entry in `active` that looks like it's still working.
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.processes[k] = nil
                self?.active.removeAll { $0.key == k }
            }
        }

        return entry
    }

    func stop(_ forward: ActiveForward) {
        processes[forward.key]?.terminate()
        processes[forward.key] = nil
        active.removeAll { $0.key == forward.key }
    }

    /// Called at app quit so forwarded `ssh -N` processes don't linger as orphans after
    /// VPSManager itself closes.
    func stopAll() {
        for process in processes.values { process.terminate() }
        processes.removeAll()
        active.removeAll()
    }
}