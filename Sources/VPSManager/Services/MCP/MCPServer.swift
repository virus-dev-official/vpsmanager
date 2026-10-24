import Foundation

/// A Model Context Protocol server over stdio, started by running the app binary
/// with `--mcp` (see Entry.swift). AI agents such as Claude Code launch it as a
/// subprocess and call its tools to inspect and operate the user's servers.
///
/// It reuses the app's own services (ShellService, SFTPService, PM2Service, …)
/// and saved servers, but never touches AppKit or the Keychain, so it runs
/// headless whether or not the app is open. Which servers it may see — and
/// whether read-only or fully — comes from mcp.json, edited in Settings ▸ AI
/// Agents, and is re-read on every call so changes apply immediately.
///
/// Wire format: newline-delimited JSON-RPC 2.0 on stdin/stdout. Nothing else may
/// ever be printed to stdout.
final class MCPServer: @unchecked Sendable {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    private static let maxOutput = 60_000

    private let writeLock = NSLock()

    static func run() -> Never {
        let server = MCPServer()
        let reader = Thread {
            while let line = readLine(strippingNewline: true) {
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                server.receive(line)
            }
            // stdin closed: the client is gone.
            exit(0)
        }
        reader.start()
        dispatchMain()
    }

    // MARK: - JSON-RPC

    private func receive(_ line: String) {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
            return
        }
        guard let method = message["method"] as? String else { return }   // a response to us; we never send requests
        let id = message["id"]
        let params = message["params"] as? [String: Any] ?? [:]

        // Notifications (no id) never get a reply.
        guard let id else { return }

        Task {
            do {
                let result = try await self.handle(method: method, params: params)
                self.send(["jsonrpc": "2.0", "id": id, "result": result])
            } catch let error as RPCError {
                self.send(["jsonrpc": "2.0", "id": id, "error": ["code": error.code, "message": error.message]])
            } catch {
                self.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]])
            }
        }
    }

    private func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        writeLock.lock()
        FileHandle.standardOutput.write(data)
        writeLock.unlock()
    }

    struct RPCError: Error {
        let code: Int
        let message: String
    }

    private func handle(method: String, params: [String: Any]) async throws -> Any {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            return [
                "protocolVersion": version,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "vps-manager", "title": "VPS Manager", "version": Bundle.main.shortVersion],
                "instructions": """
                Tools for the user's own Linux servers (VPSes), managed through the VPS Manager Mac app. \
                Start with list_servers to see which servers you may use and your access level on each \
                (read_only or full). Pass a server's name or id as `server`. Read-only servers reject \
                anything that changes state. Prefer the specific tools (pm2_*, systemd_*, docker_*) over \
                run_command when one fits. Every call is logged and visible to the user.
                """,
            ]
        case "ping":
            return [String: Any]()
        case "tools/list":
            return ["tools": Self.tools.map(\.descriptor)]
        case "tools/call":
            guard let name = params["name"] as? String else {
                throw RPCError(code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return await callTool(name: name, arguments: arguments)
        default:
            throw RPCError(code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tool dispatch

    private func callTool(name: String, arguments: [String: Any]) async -> [String: Any] {
        guard let tool = Self.tools.first(where: { $0.name == name }) else {
            return toolResult("Unknown tool: \(name)", isError: true)
        }
        let config = MCPConfig.load()
        guard config.enabled else {
            return toolResult("AI agent access is turned off. The user can enable it in VPS Manager ▸ Settings ▸ AI Agents.", isError: true)
        }

        let args = Arguments(raw: arguments)
        var server: Server?
        if tool.needsServer {
            do {
                server = try resolveServer(args.string("server"), config: config)
            } catch {
                log(tool: name, server: args.string("server"), summary: error.localizedDescription, outcome: .denied)
                return toolResult(error.localizedDescription, isError: true)
            }
            if tool.requires == .full, let server, config.access(for: server.id) != .full {
                let message = "\(server.nickname) is read-only for AI agents; \(name) changes the server. The user can grant Full access in VPS Manager ▸ Settings ▸ AI Agents."
                log(tool: name, server: server.nickname, summary: tool.summarize(args), outcome: .denied)
                return toolResult(message, isError: true)
            }
        }

        do {
            let output = try await tool.run(args, server, config)
            log(tool: name, server: server?.nickname, summary: tool.summarize(args), outcome: .ok)
            return toolResult(output, isError: false)
        } catch {
            log(tool: name, server: server?.nickname, summary: tool.summarize(args) + " — " + error.localizedDescription, outcome: .failed)
            return toolResult(error.localizedDescription, isError: true)
        }
    }

    private func toolResult(_ text: String, isError: Bool) -> [String: Any] {
        var body = text
        if body.count > Self.maxOutput {
            body = String(body.prefix(Self.maxOutput)) + "\n… [truncated — \(text.count - Self.maxOutput) more characters]"
        }
        return ["content": [["type": "text", "text": body]], "isError": isError]
    }

    private func log(tool: String, server: String?, summary: String, outcome: MCPActivity.Outcome) {
        MCPActivity.append(MCPActivity(date: Date(), tool: tool, server: server, summary: String(summary.prefix(300)), outcome: outcome))
    }

    // MARK: - Servers

    static func allServers() -> [Server] {
        DiskStore.shared.load("servers.json", as: [Server].self, default: [])
    }

    static func visibleServers(_ config: MCPConfig) -> [Server] {
        allServers().filter { config.access(for: $0.id) != .off }
    }

    /// Accepts an id, nickname, user@host or bare host. Servers switched off
    /// for agents are treated as if they didn't exist.
    private func resolveServer(_ query: String?, config: MCPConfig) throws -> Server {
        let candidates = Self.visibleServers(config)
        let names = candidates.map { "\($0.nickname) (\($0.sshTarget))" }.joined(separator: ", ")
        guard let query = query?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            throw ToolError("Missing `server`. Available: \(names.isEmpty ? "none — no servers are enabled for AI agents" : names)")
        }
        let q = query.lowercased()
        let matchers: [(Server) -> Bool] = [
            { $0.id.uuidString.lowercased() == q },
            { $0.nickname.lowercased() == q },
            { $0.sshTarget.lowercased() == q || "\($0.sshTarget):\($0.port)".lowercased() == q },
            { $0.host.lowercased() == q },
        ]
        for matches in matchers {
            let found = candidates.filter(matches)
            if found.count == 1 { return found[0] }
            if found.count > 1 {
                throw ToolError("`\(query)` matches several servers: \(found.map { "\($0.nickname) (\($0.sshTarget))" }.joined(separator: ", ")). Use the name or user@host.")
            }
        }
        throw ToolError("No server named `\(query)` is available to AI agents. Available: \(names.isEmpty ? "none" : names)")
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Typed access to a tool call's JSON arguments.
struct Arguments {
    let raw: [String: Any]

    func string(_ key: String) -> String? {
        if let s = raw[key] as? String { return s }
        if let n = raw[key] as? NSNumber { return n.stringValue }
        return nil
    }

    func requiredString(_ key: String) throws -> String {
        guard let value = string(key), !value.isEmpty else { throw ToolError("Missing required argument `\(key)`.") }
        return value
    }

    func int(_ key: String, default value: Int, range: ClosedRange<Int>) -> Int {
        let parsed = (raw[key] as? NSNumber)?.intValue ?? string(key).flatMap(Int.init) ?? value
        return min(max(parsed, range.lowerBound), range.upperBound)
    }

    func bool(_ key: String, default value: Bool) -> Bool {
        (raw[key] as? Bool) ?? (raw[key] as? NSNumber)?.boolValue ?? value
    }
}
