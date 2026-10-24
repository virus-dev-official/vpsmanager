import SwiftUI

struct ProjectEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID

    @State private var name: String = ""
    @State private var excludeText: String = ""
    @State private var autoSyncOnSave: Bool = false
    @State private var autoSyncDeletes: Bool = false
    @State private var localPath: String = ""
    @State private var remotePath: String = ""

    private var project: Project? { store.projects.first(where: { $0.id == projectID }) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Project Settings").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(20)
            Divider()

            Form {
                Section("Name") {
                    TextField("Name", text: $name)
                }

                Section("Paths") {
                    LabeledContent("Local", value: localPath)
                    LabeledContent("Remote", value: remotePath)
                    Text("To change which folders are linked, remove this link and create a new one — paths aren't editable in place since it could point sync at the wrong place unintentionally.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Exclude from Sync") {
                    TextEditor(text: $excludeText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 180)
                    Text("One gitignore-style pattern per line. Applied on every push via rsync's --exclude-from.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        quickAddButton(".env")
                        quickAddButton("node_modules/")
                        quickAddButton(".git/")
                        quickAddButton("__pycache__/")
                        quickAddButton("venv/")
                        quickAddButton("dist/")
                        quickAddButton(".DS_Store")
                    }
                }

                Section("Sync Behavior") {
                    Toggle("Auto-sync when files change", isOn: $autoSyncOnSave)
                    Toggle("Also delete server files removed locally", isOn: $autoSyncDeletes)
                        .disabled(!autoSyncOnSave)
                        .help("Off: auto-sync only adds and updates files. Deletions still go through when you Review & Push manually.")
                    Text("When on, this project pushes automatically shortly after you save a file locally, in addition to manual pushes from the diff view.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 640)
        .onAppear { loadFromProject() }
    }

    private func quickAddButton(_ pattern: String) -> some View {
        Button(pattern) {
            var lines = excludeText.split(separator: "\n").map(String.init)
            if !lines.contains(pattern) {
                lines.append(pattern)
                excludeText = lines.joined(separator: "\n")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func loadFromProject() {
        guard let project else { return }
        name = project.name
        excludeText = project.excludePatterns.joined(separator: "\n")
        autoSyncOnSave = project.autoSyncOnSave
        autoSyncDeletes = project.autoSyncDeletes
        localPath = project.localPath
        remotePath = project.remotePath
    }

    private func save() {
        guard let idx = store.projects.firstIndex(where: { $0.id == projectID }) else { dismiss(); return }
        store.projects[idx].name = name
        store.projects[idx].excludePatterns = excludeText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.projects[idx].autoSyncOnSave = autoSyncOnSave
        store.projects[idx].autoSyncDeletes = autoSyncDeletes
        dismiss()
    }
}