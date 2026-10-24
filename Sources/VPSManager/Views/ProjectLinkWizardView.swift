import SwiftUI
import AppKit

struct ProjectLinkWizardView: View {
    let server: Server
    var onComplete: (Project) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var localPath = ""
    @State private var remotePath = ""
    @State private var excludeText = ".git/\n.env\nnode_modules/\n__pycache__/\n.DS_Store\nvenv/\n.venv/"
    @State private var remoteExists: Bool?
    @State private var checking = false
    @State private var creating = false
    @State private var linkedProject: Project?
    @State private var completed = false
    @State private var log = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Link Project to \(server.nickname)").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
                    .disabled(creating)
            }
            .padding(20)
            Divider()

            Form {
                Section("Project Name") {
                    TextField("Name", text: $name, prompt: Text("my-app"))
                }

                Section("Local Folder") {
                    HStack {
                        TextField("Local path", text: $localPath, prompt: Text("~/Developer/my-app"))
                        Button("Choose…") { chooseLocalFolder() }
                    }
                }

                Section("Remote Folder (on \(server.nickname))") {
                    HStack {
                        TextField("Remote path", text: $remotePath, prompt: Text("/home/\(server.user)/my-app"))
                            .onChange(of: remotePath) { _, _ in remoteExists = nil }
                        Button("Check") { Task { await checkRemote() } }
                    }
                    if checking {
                        ProgressView().controlSize(.small)
                    } else if let remoteExists {
                        if remoteExists {
                            Label("Folder exists — will sync and update changed files only.", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.secondary).font(.callout)
                        } else {
                            Label("Folder doesn't exist yet — will be created and fully pushed.", systemImage: "plus.circle.fill")
                                .foregroundStyle(.secondary).font(.callout)
                        }
                    }
                }

                Section("Exclude from Sync") {
                    TextEditor(text: $excludeText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 100)
                    Text("One pattern per line, gitignore-style.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                if !log.isEmpty {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 110)
                    .background(.black.opacity(0.85))
                    .foregroundStyle(Color(white: 0.85))
                }
            }
            .formStyle(.grouped)
            .disabled(creating || linkedProject != nil)

            HStack {
                Spacer()
                if creating {
                    ProgressView("Pushing initial files…")
                        .controlSize(.small)
                } else if completed {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(linkedProject == nil ? "Link & Push Initial Files" : "Retry Initial Push") {
                        Task { await linkAndPush() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              localPath.isEmpty || remotePath.isEmpty || creating)
                }
            }
            .padding(20)
        }
        .frame(width: 620, height: 640)
    }

    func chooseLocalFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            localPath = url.path
            if name.isEmpty { name = url.lastPathComponent }
        }
    }

    func checkRemote() async {
        checking = true
        defer { checking = false }
        do {
            remoteExists = try await SyncService.shared.remoteFolderExists(server, remotePath: remotePath)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func linkAndPush() async {
        creating = true
        errorMessage = nil
        log = ""
        defer { creating = false }
        do {
            var project = linkedProject
            if project == nil {
                let resolvedLocalPath = (localPath as NSString).expandingTildeInPath
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: resolvedLocalPath, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw NSError(domain: "ProjectLinkWizard", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "The selected local path is not an existing folder."
                    ])
                }

                log += "Checking remote folder…\n"
                let exists = try await SyncService.shared.remoteFolderExists(server, remotePath: remotePath)
                if !exists {
                    log += "Creating remote folder…\n"
                    try await SyncService.shared.createRemoteFolder(server, remotePath: remotePath)
                }

                let newProject = Project(
                    serverID: server.id,
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    localPath: resolvedLocalPath,
                    remotePath: remotePath,
                    excludePatterns: excludeText.split(separator: "\n").map(String.init)
                )
                project = newProject
                linkedProject = newProject
                onComplete(newProject)
            }

            guard var project else { return }
            log += "\nPushing initial files…\n"
            try await SyncService.shared.push(server: server, project: project) { output in
                log += output
            }
            project.lastSyncedAt = Date()
            linkedProject = project
            onComplete(project)
            completed = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
            log += "\n\(error.localizedDescription)\n"
        }
    }
}