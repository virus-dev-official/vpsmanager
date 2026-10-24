import SwiftUI
import AppKit

/// Settings ▸ AI Agents: turn the MCP server on, choose what agents may do on
/// each server, copy the setup command, and review what agents have done.
struct AgentsSettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var config = MCPConfig.load()
    @State private var activity: [MCPActivity] = []
    @State private var copied: String?

    private let refresh = Timer.publish(every: 3, on: .main, in: .common).autoconnect()

    private var executablePath: String {
        Bundle.main.executablePath ?? "/Applications/VPSManager.app/Contents/MacOS/VPSManager"
    }

    private var claudeCodeCommand: String {
        "claude mcp add vps-manager --scope user -- \"\(executablePath)\" --mcp"
    }

    private var jsonConfig: String {
        """
        {
          "mcpServers": {
            "vps-manager": {
              "command": "\(executablePath)",
              "args": ["--mcp"]
            }
          }
        }
        """
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI agents to use VPS Manager (MCP)", isOn: $config.enabled)
                Text("Agents like Claude Code connect through the Model Context Protocol and can check status, read logs and files, and — where you allow it — run commands on your servers. They use the same SSH keys as the app; nothing leaves your Mac except the SSH connections themselves.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Server Access") {
                if store.servers.isEmpty {
                    Text("Add a server first.").foregroundStyle(.secondary)
                }
                ForEach(store.servers) { server in
                    LabeledContent {
                        Picker("", selection: Binding(
                            get: { config.access(for: server.id) },
                            set: { config.setAccess($0, for: server.id) }
                        )) {
                            ForEach(AgentAccess.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 260)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.nickname)
                            Text(server.sshTarget).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("**Read-only:** status, logs, listings and file reads. **Full access:** also runs shell commands, writes files and starts/stops services, containers and PM2 apps — with the same rights as the SSH user.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!config.enabled)

            Section("Connect an Agent") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Code — run once in Terminal:").font(.callout.weight(.medium))
                    snippet(claudeCodeCommand, id: "cli")
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Desktop, Cursor and other MCP clients — add to their MCP config:").font(.callout.weight(.medium))
                    snippet(jsonConfig, id: "json")
                }
                Text("The agent starts VPS Manager in the background when it needs it; the app window doesn't have to be open.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if activity.isEmpty {
                    Text("Nothing yet. Every tool call an agent makes shows up here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(activity.prefix(60)) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: entry.outcome))
                                .foregroundStyle(tint(for: entry.outcome))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(entry.tool).font(.callout.monospaced().weight(.medium))
                                    if let server = entry.server {
                                        Text("on \(server)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if !entry.summary.isEmpty {
                                    Text(entry.summary)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                            }
                            Spacer()
                            Text(entry.date, format: .relative(presentation: .named))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent Agent Activity")
                    Spacer()
                    Button("Clear") {
                        MCPActivity.clear()
                        activity = []
                    }
                    .controlSize(.small)
                    .disabled(activity.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: config) { _, newValue in newValue.save() }
        .onAppear {
            config = MCPConfig.load()
            activity = MCPActivity.recent()
        }
        .onReceive(refresh) { _ in activity = MCPActivity.recent() }
    }

    private func snippet(_ text: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied == id ? "Copied" : "Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = id
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if copied == id { copied = nil } }
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func icon(for outcome: MCPActivity.Outcome) -> String {
        switch outcome {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .denied: return "hand.raised.fill"
        }
    }

    private func tint(for outcome: MCPActivity.Outcome) -> Color {
        switch outcome {
        case .ok: return Theme.success
        case .failed: return Theme.danger
        case .denied: return Theme.warning
        }
    }
}
