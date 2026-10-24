import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @State private var importMessage: String?
    @State private var importSucceeded = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw = AppearanceMode.system.rawValue
    @AppStorage(BrowserQuality.storageKey) private var qualityRaw = BrowserQuality.sharp.rawValue
    @AppStorage(BrowserSearchEngine.storageKey) private var searchRaw = BrowserSearchEngine.duckDuckGo.rawValue
    @AppStorage(BrowserPreferences.keepRunningKey) private var keepBrowserRunning = true
    @AppStorage(BackupManager.enabledKey) private var autoBackupEnabled = false
    @AppStorage(BackupManager.folderKey) private var autoBackupFolder = BackupManager.defaultFolder
    @AppStorage(BackupManager.gitKey) private var autoBackupUseGit = false
    @ObservedObject private var backups = BackupManager.shared

    var body: some View {
        TabView {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: appearanceRaw) { _, raw in
                        (AppearanceMode(rawValue: raw) ?? .system).apply()
                    }
                }
                Section("Background") {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { LaunchAtLoginManager.isEnabled },
                        set: { LaunchAtLoginManager.setEnabled($0) }
                    ))
                    Toggle("Run in Background (hide Dock icon at launch)", isOn: Binding(
                        get: { BackgroundModeManager.isEnabled },
                        set: { BackgroundModeManager.setEnabled($0) }
                    ))
                    Text("When on, the app starts quietly in the menu bar with no Dock icon and no window. Click the menu bar icon anytime to open it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Default SSH Key") {
                    Text("New servers created via the setup wizard use ~/.ssh/id_ed25519 by default. Existing keys are reused automatically.")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                Section("Data") {
                    LabeledContent("Servers", value: "\(store.servers.count)")
                    LabeledContent("Linked Projects", value: "\(store.projects.count)")
                    LabeledContent("PM2 Apps Tracked", value: "\(store.pm2Configs.count)")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form {
                Section("Browsing") {
                    Picker("Search Engine", selection: $searchRaw) {
                        ForEach(BrowserSearchEngine.allCases) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                    Text("Used for searches typed in the address bar and as the start page for new tabs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Stream Quality") {
                    Picker("Quality", selection: $qualityRaw) {
                        ForEach(BrowserQuality.allCases) { quality in
                            Text(quality.title).tag(quality.rawValue)
                        }
                    }
                    Text(BrowserQuality(rawValue: qualityRaw)?.detail ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("On the VPS") {
                    Toggle("Keep the browser running after disconnecting", isOn: $keepBrowserRunning)
                    Text(keepBrowserRunning
                         ? "Tabs, logins and cookies are waiting exactly where you left them next time. Chromium keeps using some memory on the server meanwhile — stop it any time from the browser's ⋯ menu."
                         : "Chromium is stopped on the server whenever you disconnect or quit, freeing its memory. Tabs are closed; logins and cookies are still saved in its profile.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Browser", systemImage: "globe") }

            AgentsSettingsView()
                .tabItem { Label("AI Agents", systemImage: "sparkles") }

            Form {
                Section("Automatic Backup") {
                    Toggle("Back up automatically when anything changes", isOn: $autoBackupEnabled)
                        .onChange(of: autoBackupEnabled) { _, on in
                            if on { Task { await backups.backUpNow() } }
                        }
                    LabeledContent("Folder") {
                        HStack {
                            Text((autoBackupFolder as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.secondary)
                            Button("Choose…") { chooseBackupFolder() }
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: (autoBackupFolder as NSString).expandingTildeInPath))
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Show in Finder")
                        }
                    }
                    Picker("Keep history", selection: $autoBackupUseGit) {
                        Text("As dated copies (last \(BackupManager.keepCount))").tag(false)
                        Text("As git commits").tag(true)
                    }
                    Group {
                        if autoBackupUseGit {
                            Text("The folder becomes a git repository and every change is committed. If it has a remote (e.g. a private GitHub repo), each commit is pushed too.")
                        } else {
                            Text("The default folder is in iCloud Drive, so backups follow you to a new Mac.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    HStack {
                        Button("Back Up Now") { Task { await backups.backUpNow() } }
                            .disabled(backups.isRunning)
                        if backups.isRunning {
                            ProgressView().controlSize(.small)
                        } else if let error = backups.lastError {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        } else if let last = backups.lastBackupAt {
                            Text("Last backup \(last.formatted(.relative(presentation: .named)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Backup") {
                    Text("Save everything the app remembers — servers, linked projects, PM2 configs, Cloudflare tunnels, and tracked systemd units — to a single file. Useful before a macOS reinstall or moving to a new Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Export Backup…") { exportBackup() }
                        Button("Import Backup…") { importBackup() }
                    }
                    if let importMessage {
                        Text(importMessage)
                            .font(.caption)
                            .foregroundStyle(importSucceeded ? Color.secondary : Color.red)
                    }
                    Text("Importing replaces everything currently in the app with the contents of the chosen file. PM2 environment variables are excluded from backups and stay in this Mac's Keychain — they'll need to be re-entered after importing on a different Mac.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Moving a whole VPS is separate: use Transfer VPS from a grouped server entry. That operation requires root SSH access and matching Linux versions, replaces destination application/user state, and preserves the destination's SSH and network identity.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Backup", systemImage: "arrow.down.doc") }
        }
        .frame(width: 620, height: 620)
        .tint(Theme.accent)
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            autoBackupFolder = url.path
        }
    }

    private func exportBackup() {
        guard let data = store.exportBackupData() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "VPSManager-backup-\(Self.dateStamp()).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url, options: .atomic)
                importMessage = "Exported to \(url.lastPathComponent)."
                importSucceeded = true
            } catch {
                importMessage = "Export failed: \(error.localizedDescription)"
                importSucceeded = false
            }
        }
    }

    private func importBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            if store.importBackupData(data) {
                importMessage = "Imported \(store.servers.count) server(s) from \(url.lastPathComponent)."
                importSucceeded = true
            } else {
                importMessage = "That file doesn't look like a valid VPS Manager backup."
                importSucceeded = false
            }
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
            importSucceeded = false
        }
    }

    private static func dateStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}