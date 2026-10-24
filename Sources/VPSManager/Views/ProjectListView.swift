import SwiftUI
import AppKit

struct ProjectListView: View {
    let server: Server
    @EnvironmentObject var store: AppStore
    @ObservedObject private var autoSync = AutoSyncManager.shared
    @State private var showingWizard = false
    @State private var selectedProject: Project?
    @State private var editingProjectID: UUID?

    var body: some View {
        let projects = store.projects(for: server.id)
        VStack(spacing: 0) {
            SectionTopBar(title: "\(projects.count) linked project\(projects.count == 1 ? "" : "s")", systemImage: "folder.badge.gearshape") {
                Button {
                    showingWizard = true
                } label: {
                    Label("Link Project", systemImage: "plus")
                }
            }

            if projects.isEmpty {
                ContentUnavailableView {
                    Label("No Linked Projects", systemImage: "folder.badge.plus")
                } description: {
                    Text("Link a local folder to a folder on \(server.nickname) to preview and push changes.")
                } actions: {
                    Button("Link a Project") { showingWizard = true }
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(projects) { project in
                            projectCard(project)
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 1100)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.canvas)
        .sheet(isPresented: $showingWizard) {
            ProjectLinkWizardView(server: server) { project in
                if let index = store.projects.firstIndex(where: { $0.id == project.id }) {
                    store.projects[index] = project
                } else {
                    store.projects.append(project)
                }
            }
        }
        .sheet(item: $selectedProject) { project in
            SyncDiffView(server: server, project: project)
        }
        .sheet(isPresented: Binding(
            get: { editingProjectID != nil },
            set: { if !$0 { editingProjectID = nil } }
        )) {
            if let editingProjectID {
                ProjectEditView(projectID: editingProjectID)
            }
        }
    }

    private func projectCard(_ project: Project) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(systemImage: "folder.fill", size: 38)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(project.name).font(.headline)
                    if project.autoSyncOnSave {
                        autoSyncBadge(for: project)
                    }
                }
                pathRow("laptopcomputer", (project.localPath as NSString).abbreviatingWithTildeInPath)
                pathRow("server.rack", project.remotePath)
                if !project.excludePatterns.isEmpty {
                    Text("Excludes: " + project.excludePatterns.joined(separator: ", "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let err = autoSync.autoSyncErrors[project.id] {
                    Label("Auto-sync: \(err)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 10) {
                Group {
                    if let last = project.lastSyncedAt {
                        Text("Synced \(last, style: .relative) ago")
                    } else {
                        Text("Never synced").fontWeight(.semibold)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Button {
                        editingProjectID = project.id
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .help("Edit exclude list and sync settings")
                    Button {
                        selectedProject = project
                    } label: {
                        Label("Review & Push", systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
        .cardBackground(padding: 16)
        .contextMenu {
            Button("Review & Push…") { selectedProject = project }
            Button("Edit Settings…") { editingProjectID = project.id }
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.localPath)
            }
            Divider()
            Button("Remove Link", role: .destructive) {
                store.projects.removeAll { $0.id == project.id }
            }
        }
    }

    private func pathRow(_ symbol: String, _ path: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .frame(width: 14)
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func autoSyncBadge(for project: Project) -> some View {
        if autoSync.autoSyncInFlight.contains(project.id) {
            Label("Syncing", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        } else {
            Label("Auto-sync", systemImage: "eye")
                .font(.caption2)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }
}