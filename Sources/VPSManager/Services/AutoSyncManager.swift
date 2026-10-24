import Foundation
import Combine

@MainActor
final class AutoSyncManager: ObservableObject {
    static let shared = AutoSyncManager()

    @Published private(set) var lastAutoSyncAt: [UUID: Date] = [:]
    @Published private(set) var autoSyncInFlight: Set<UUID> = []
    @Published private(set) var autoSyncErrors: [UUID: String] = [:]

    private var watchers: [UUID: FileWatcher] = [:]
    private var debounceWorkItems: [UUID: DispatchWorkItem] = [:]
    private weak var store: AppStore?
    private var cancellable: AnyCancellable?

    /// Hooks the manager up to the app's data store and starts watching whatever
    /// projects currently have auto-sync enabled. Also re-reconciles automatically
    /// whenever the project list changes (toggled on/off, added, removed).
    func attach(store: AppStore) {
        self.store = store
        reconcile()
        cancellable = store.$projects
            .removeDuplicates()
            .sink { [weak self] _ in self?.reconcile() }
    }

    /// Adds/removes file watchers so the active set matches exactly the projects
    /// that currently have auto-sync turned on. Safe to call anytime state changes.
    func reconcile() {
        guard let store else { return }
        let active = store.projects.filter { $0.autoSyncOnSave }
        let activeIDs = Set(active.map(\.id))

        for id in watchers.keys where !activeIDs.contains(id) {
            watchers[id]?.stop()
            watchers.removeValue(forKey: id)
        }

        for project in active where watchers[project.id] == nil {
            let watcher = FileWatcher(path: (project.localPath as NSString).expandingTildeInPath) { [weak self] in
                Task { @MainActor in self?.scheduleSync(projectID: project.id) }
            }
            watcher.start()
            watchers[project.id] = watcher
        }
    }

    private func scheduleSync(projectID: UUID) {
        debounceWorkItems[projectID]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.performSync(projectID: projectID) }
        }
        debounceWorkItems[projectID] = work
        // Debounce so a burst of file writes (a build, a save-all, git operations)
        // collapses into a single push a few seconds after things settle down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func performSync(projectID: UUID) async {
        guard let store,
              let project = store.projects.first(where: { $0.id == projectID }),
              let server = store.server(project.serverID) else { return }

        autoSyncInFlight.insert(projectID)
        defer { autoSyncInFlight.remove(projectID) }
        do {
            // Auto-sync has no human in the loop to see a warning dialog, so it
            // errs on the side of NOT pushing if the server has changes newer than
            // the last sync — better to skip a cycle and let the user resolve it
            // from the Projects tab than to silently clobber a server-side edit.
            if let lastSynced = project.lastSyncedAt {
                let changes = try await SyncService.shared.previewChanges(server: server, project: project)
                let pathsToCheck = changes.filter { $0.kind == .update || $0.kind == .delete }.map(\.path)
                let modified = await SyncService.shared.remoteModifiedSince(server: server, project: project, paths: pathsToCheck, since: lastSynced)
                if !modified.isEmpty {
                    autoSyncErrors[projectID] = "Skipped: \(modified.count) file(s) changed on the server since last sync. Review and push manually."
                    return
                }
            }

            try await SyncService.shared.push(server: server, project: project, deleteRemoved: project.autoSyncDeletes)
            lastAutoSyncAt[projectID] = Date()
            autoSyncErrors[projectID] = nil
            if let idx = store.projects.firstIndex(where: { $0.id == projectID }) {
                store.projects[idx].lastSyncedAt = Date()
            }
        } catch {
            autoSyncErrors[projectID] = error.localizedDescription
        }
    }
}