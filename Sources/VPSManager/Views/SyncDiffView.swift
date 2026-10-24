import SwiftUI

struct SyncDiffView: View {
    let server: Server
    let project: Project
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var changes: [SyncChange] = []
    @State private var loading = true
    @State private var pushing = false
    @State private var errorMessage: String?
    @State private var pushLog = ""
    @State private var didPush = false
    @State private var showingSettings = false
    @State private var remotelyModifiedPaths: Set<String> = []
    @State private var showingOverwriteConfirm = false

    var currentProject: Project { store.projects.first(where: { $0.id == project.id }) ?? project }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text(currentProject.name).font(.title2.bold())
                    Text("\(currentProject.localPath)  →  \(server.sshTarget):\(currentProject.remotePath)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Edit exclude list and sync settings")
                Button("Close") { dismiss() }
            }
            .padding(20)
            Divider()

            if !remotelyModifiedPaths.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.primary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(remotelyModifiedPaths.count) file\(remotelyModifiedPaths.count == 1 ? "" : "s") changed on the server since your last sync.")
                            .font(.callout.bold())
                        Text("Pushing will overwrite \(remotelyModifiedPaths.count == 1 ? "it" : "them") with your local version. Check the flagged rows below before pushing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.quaternary.opacity(0.5))
            }

            if loading {
                Spacer()
                ProgressView("Comparing local and remote files…")
                Spacer()
            } else if let errorMessage {
                Spacer()
                Text(errorMessage).foregroundStyle(.red).padding()
                Spacer()
            } else if changes.isEmpty && !didPush {
                ContentUnavailableView("Everything Up to Date", systemImage: "checkmark.circle",
                    description: Text("No differences found between local and remote."))
            } else {
                List(changes) { change in
                    HStack {
                        Image(systemName: icon(for: change.kind))
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        Text(change.path).font(.system(.body, design: .monospaced))
                        if remotelyModifiedPaths.contains(change.path) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.primary)
                                .help("Changed on the server since your last sync")
                        }
                        Spacer()
                        Text(label(for: change.kind)).font(.caption.bold()).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }

            if !pushLog.isEmpty {
                ScrollView {
                    Text(pushLog).font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 80)
                .background(.black.opacity(0.85))
                .foregroundStyle(Color(white: 0.85))
            }

            Divider()
            HStack {
                Button("Refresh Diff") { Task { await loadDiff() } }
                Spacer()
                if pushing {
                    ProgressView().controlSize(.small)
                }
                Button(didPush ? "Pushed ✓" : "Push Changes") {
                    if !remotelyModifiedPaths.isEmpty {
                        showingOverwriteConfirm = true
                    } else {
                        Task { await push() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(pushing || (changes.isEmpty && !didPush) || didPush)
            }
            .padding(16)
        }
        .frame(width: 640, height: 560)
        .task { await loadDiff() }
        .sheet(isPresented: $showingSettings, onDismiss: {
            Task { await loadDiff() } // re-run with any updated exclude patterns
        }) {
            ProjectEditView(projectID: project.id)
        }
        .alert("Overwrite server changes?", isPresented: $showingOverwriteConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Push Anyway", role: .destructive) {
                Task { await push() }
            }
        } message: {
            Text("\(remotelyModifiedPaths.count) file\(remotelyModifiedPaths.count == 1 ? "" : "s") on the server changed after your last sync. Pushing will replace \(remotelyModifiedPaths.count == 1 ? "it" : "them") with your local version, and that server-side edit will be lost.")
        }
    }

    func icon(for kind: SyncChange.Kind) -> String {
        switch kind {
        case .create: return "plus.circle.fill"
        case .update: return "arrow.triangle.2.circlepath.circle.fill"
        case .delete: return "minus.circle.fill"
        case .createDir: return "folder.badge.plus"
        }
    }
    func label(for kind: SyncChange.Kind) -> String {
        switch kind {
        case .create: return "New"
        case .update: return "Modified"
        case .delete: return "Will Delete"
        case .createDir: return "New Folder"
        }
    }

    func loadDiff() async {
        loading = true
        errorMessage = nil
        didPush = false
        remotelyModifiedPaths = []
        do {
            changes = try await SyncService.shared.previewChanges(server: server, project: currentProject)
            if let lastSynced = currentProject.lastSyncedAt {
                // Only bother checking files that would actually be overwritten
                // (updates/deletes) — new files can't have a server-side edit to lose.
                let pathsToCheck = changes.filter { $0.kind == .update || $0.kind == .delete }.map(\.path)
                remotelyModifiedPaths = await SyncService.shared.remoteModifiedSince(
                    server: server, project: currentProject, paths: pathsToCheck, since: lastSynced
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    func push() async {
        pushing = true
        defer { pushing = false }
        do {
            try await SyncService.shared.push(server: server, project: currentProject) { output in
                pushLog = output
            }
            didPush = true
            remotelyModifiedPaths = []
            if let idx = store.projects.firstIndex(where: { $0.id == project.id }) {
                store.projects[idx].lastSyncedAt = Date()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}