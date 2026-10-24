import Foundation

struct DockerContainer: Identifiable, Hashable {
    let id: String
    let name: String
    let image: String
    let state: String        // running, exited, paused, restarting, created, dead
    let status: String       // "Up 3 hours", "Exited (0) 2 days ago"
    let ports: String
    var cpu: String? = nil
    var memory: String? = nil

    var isRunning: Bool { state == "running" }
}

struct DockerImage: Identifiable, Hashable {
    let id: String
    let repository: String
    let tag: String
    let size: String
    let created: String

    var displayName: String {
        repository == "<none>" ? id : "\(repository):\(tag)"
    }
}

/// Docker over SSH via the `docker` CLI. Uses `sudo -n docker` when the user
/// isn't in the docker group but has passwordless sudo.
final class DockerService {
    static let shared = DockerService()

    enum Availability { case available, notInstalled, noPermission }

    /// Picks `docker` or `sudo -n docker` into $D for the rest of the command.
    private let prelude = """
    command -v docker >/dev/null 2>&1 || { echo __NO_DOCKER__; exit 0; }
    D=docker; docker ps -q >/dev/null 2>&1 || D="sudo -n docker"
    $D ps -q >/dev/null 2>&1 || { echo __NO_PERMISSION__; exit 0; }
    """

    private func run(_ server: Server, _ body: String, timeout: TimeInterval = 30) async throws -> (Availability, String) {
        let cmd = prelude + "\n" + body
        let output = try await ShellService.shared.sshExpectingSuccess(server, command: cmd, timeout: timeout)
        if output.contains("__NO_DOCKER__") { return (.notInstalled, "") }
        if output.contains("__NO_PERMISSION__") { return (.noPermission, "") }
        return (.available, output)
    }

    func containers(_ server: Server) async throws -> (Availability, [DockerContainer]) {
        let (availability, output) = try await run(server, """
        $D ps -a --no-trunc --format '{{json .}}'
        echo __STATS__
        $D stats --no-stream --format '{{json .}}' 2>/dev/null
        """)
        guard availability == .available else { return (availability, []) }
        let sections = output.components(separatedBy: "__STATS__")
        var stats: [String: (String, String)] = [:]
        if sections.count > 1 {
            for object in jsonLines(sections[1]) {
                guard let id = object["ID"] as? String else { continue }
                stats[String(id.prefix(12))] = (object["CPUPerc"] as? String ?? "", object["MemUsage"] as? String ?? "")
            }
        }
        let containers = jsonLines(sections[0]).compactMap { object -> DockerContainer? in
            guard let id = object["ID"] as? String else { return nil }
            let short = String(id.prefix(12))
            return DockerContainer(
                id: short,
                name: (object["Names"] as? String ?? short).trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                image: object["Image"] as? String ?? "",
                state: (object["State"] as? String ?? "").lowercased(),
                status: object["Status"] as? String ?? "",
                ports: object["Ports"] as? String ?? "",
                cpu: stats[short]?.0,
                memory: stats[short]?.1
            )
        }
        return (.available, containers.sorted { ($0.isRunning ? 0 : 1, $0.name) < ($1.isRunning ? 0 : 1, $1.name) })
    }

    func images(_ server: Server) async throws -> [DockerImage] {
        let (availability, output) = try await run(server, "$D images --format '{{json .}}'")
        guard availability == .available else { return [] }
        return jsonLines(output).compactMap { object in
            guard let id = object["ID"] as? String else { return nil }
            return DockerImage(id: id, repository: object["Repository"] as? String ?? "<none>",
                               tag: object["Tag"] as? String ?? "", size: object["Size"] as? String ?? "",
                               created: object["CreatedSince"] as? String ?? "")
        }
    }

    enum ContainerAction: String {
        case start, stop, restart, pause, unpause
        case remove = "rm -f"
    }

    func perform(_ action: ContainerAction, on container: DockerContainer, server: Server) async throws {
        _ = try await run(server, "$D \(action.rawValue) \(shellQuoted(container.id))", timeout: 90)
    }

    func removeImage(_ image: DockerImage, server: Server) async throws {
        _ = try await run(server, "$D rmi \(shellQuoted(image.id))", timeout: 90)
    }

    /// Removes dangling images, stopped containers and unused networks, then
    /// reports how much space came back.
    func prune(_ server: Server) async throws -> String {
        let (_, output) = try await run(server, "$D system prune -f 2>&1 | tail -1", timeout: 300)
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Command for LiveLogView to follow a container's logs.
    func logsCommand(for container: DockerContainer) -> String {
        "D=docker; docker ps -q >/dev/null 2>&1 || D=\"sudo -n docker\"; exec $D logs -f --tail 300 \(shellQuoted(container.id)) 2>&1"
    }

    private func jsonLines(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}
