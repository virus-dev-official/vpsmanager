import Foundation

final class ServerControlService {
    static let shared = ServerControlService()

    func restart(_ server: Server) async throws {
        let unit = "vpsmanager-reboot-\(UUID().uuidString.lowercased())"
        let privilegePrefix = server.user == "root" ? "" : "sudo -n "
        let command = "\(privilegePrefix)systemd-run --quiet --no-block --unit=\(unit) --on-active=5s /bin/systemctl reboot"
        let result = try await ShellService.shared.ssh(server, command: command, timeout: 20)
        guard result.success else {
            let details = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "No output was returned."
            throw NSError(domain: "ServerControlService", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "The reboot request was rejected (exit code \(result.exitCode)): \(details)"
            ])
        }
    }
}
