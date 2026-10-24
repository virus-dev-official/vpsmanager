import Foundation

enum PM2AppType: String, Codable, CaseIterable, Identifiable {
    case node = "Node.js"
    case python = "Python"
    var id: String { rawValue }
}

enum PM2ExecMode: String, Codable, CaseIterable, Identifiable {
    case fork, cluster
    var id: String { rawValue }
}

/// Saved locally so the wizard can regenerate/edit ecosystem files later.
struct PM2AppConfig: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var serverID: UUID
    var projectID: UUID?
    var name: String
    var type: PM2AppType
    var remoteEntryFile: String        // e.g. /home/deploy/my-app/dist/index.js or app.py
    var remoteCwd: String              // working directory on server
    var interpreterPath: String = ""   // python venv interpreter, blank for node
    var venvPath: String = ""          // e.g. /home/deploy/my-app/venv
    var args: String = ""
    var env: [String: String] = [:]
    var execMode: PM2ExecMode = .fork
    var instances: Int = 1
    var maxMemoryRestart: String = ""  // e.g. "300M"
    var watch: Bool = false
    var createdAt: Date = Date()

    /// Generates a pm2 ecosystem.config.js file body for this app.
    func ecosystemJS() -> String {
        let script: String
        var interpreter = ""
        if type == .node {
            script = remoteEntryFile
        } else {
            script = remoteEntryFile
            interpreter = interpreterPath.isEmpty ? "\(venvPath)/bin/python" : interpreterPath
        }

        let envLines = env.map { "        \"\($0.key)\": \"\($0.value.replacingOccurrences(of: "\"", with: "\\\""))\"" }
        let envBlock = envLines.isEmpty ? "{}" : "{\n\(envLines.joined(separator: ",\n"))\n      }"

        var lines: [String] = []
        lines.append("      name: \"\(name)\",")
        lines.append("      script: \"\(script)\",")
        lines.append("      cwd: \"\(remoteCwd)\",")
        if !interpreter.isEmpty {
            lines.append("      interpreter: \"\(interpreter)\",")
        }
        if !args.isEmpty {
            lines.append("      args: \"\(args)\",")
        }
        lines.append("      exec_mode: \"\(execMode.rawValue)\",")
        lines.append("      instances: \(execMode == .cluster ? instances : 1),")
        lines.append("      watch: \(watch ? "true" : "false"),")
        if !maxMemoryRestart.isEmpty {
            lines.append("      max_memory_restart: \"\(maxMemoryRestart)\",")
        }
        lines.append("      env: \(envBlock)")

        return """
        module.exports = {
          apps: [
            {
        \(lines.joined(separator: "\n"))
            }
          ]
        };
        """
    }
}

/// Parsed live from `pm2 jlist` on the server — not persisted.
struct PM2ProcessStatus: Identifiable, Hashable {
    var id: Int          // pm_id
    var name: String
    var status: String   // online, stopped, errored, etc.
    var cpu: Double
    var memoryMB: Double
    var uptimeMs: Double
    var restarts: Int
}