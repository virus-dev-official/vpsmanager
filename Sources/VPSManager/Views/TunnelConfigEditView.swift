import SwiftUI

/// Lets the user fix a tunnel's config path (if discovery got it wrong) and edit the
/// raw config.yml contents directly, restarting the right systemd unit on save.
struct TunnelConfigEditView: View {
    let server: Server
    let tunnelID: UUID
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var configPath: String = ""
    @State private var systemdUnit: String = ""
    @State private var contents: String = ""
    @State private var original: String = ""
    @State private var loading = true
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var restartAfterSave = true

    private var tunnel: CloudflareTunnel? { store.tunnels.first(where: { $0.id == tunnelID }) }
    private var hasChanges: Bool { contents != original }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(tunnel?.tunnelName ?? "Tunnel").font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(20)
            Divider()

            Form {
                Section("Config Path") {
                    TextField("Config path", text: $configPath)
                        .font(.system(.body, design: .monospaced))
                    Text("If this was auto-detected incorrectly, fix it here and hit Reload.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Reload from this path") { Task { await load() } }
                        Spacer()
                    }
                }

                Section("Systemd Unit") {
                    TextField("Unit name (without .service)", text: $systemdUnit)
                        .font(.system(.body, design: .monospaced))
                    Text("Restarted after saving, so changes actually take effect.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("config.yml") {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        TextEditor(text: $contents)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 280)
                    }
                    Toggle("Restart \(systemdUnit.isEmpty ? "service" : systemdUnit) after saving", isOn: $restartAfterSave)
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if hasChanges {
                    Text("Unsaved changes").font(.caption.bold()).foregroundStyle(.secondary)
                }
                Spacer()
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || configPath.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 640, height: 640)
        .task {
            configPath = tunnel?.configPath ?? ""
            systemdUnit = tunnel?.systemdUnit ?? "cloudflared"
            await load()
        }
    }

    func load() async {
        guard !configPath.isEmpty else { return }
        loading = true
        errorMessage = nil
        do {
            let text = try await SFTPService.shared.readFile(server, path: configPath)
            contents = text
            original = text
        } catch {
            errorMessage = "Couldn't read \(configPath): \(error.localizedDescription)"
            contents = ""
            original = ""
        }
        loading = false
    }

    func save() async {
        saving = true
        errorMessage = nil
        defer { saving = false }
        do {
            if restartAfterSave {
                try await CloudflaredService.shared.saveConfigAndRestart(server: server, configPath: configPath, contents: contents, unit: systemdUnit)
            } else {
                try await CloudflaredService.shared.saveConfig(server: server, configPath: configPath, contents: contents)
            }
            original = contents

            // Persist the corrected path/unit and re-sync routes from the saved content.
            if let idx = store.tunnels.firstIndex(where: { $0.id == tunnelID }) {
                store.tunnels[idx].configPath = configPath
                store.tunnels[idx].systemdUnit = systemdUnit
            }
            let parsed = ConfigYAMLBuilder.parseIngress(contents)
            store.routes.removeAll { $0.tunnelID == tunnelID }
            for r in parsed {
                guard let port = r.port else { continue }
                store.routes.append(TunnelRoute(tunnelID: tunnelID, hostname: r.hostname, localPort: port))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}