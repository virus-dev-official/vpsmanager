import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FileBrowserView: View {
    let server: Server
    @EnvironmentObject var store: AppStore

    @State private var currentPath: String
    @State private var files: [RemoteFile] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var pathHistory: [String] = []
    @State private var showHiddenFiles = false

    @State private var editingFile: RemoteFile?
    @State private var showingNewFileSheet = false
    @State private var showingNewFolderSheet = false
    @State private var newItemName = ""

    @State private var renamingFile: RemoteFile?
    @State private var renameText = ""

    @State private var uploads: [UploadTask] = []
    @State private var targetedPaths: Set<String> = []
    @State private var isBrowserDropTargeted = false
    @State private var isExtracting: Set<String> = []

    init(server: Server) {
        self.server = server
        let remembered = FileBrowserPathStore.lastPath(for: server)
        _currentPath = State(initialValue: remembered ?? "/home/\(server.user)")
    }

    private var visibleFiles: [RemoteFile] {
        showHiddenFiles ? files : files.filter { !$0.name.hasPrefix(".") }
    }

    private var hiddenCount: Int { files.count - files.filter { !$0.name.hasPrefix(".") }.count }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            breadcrumbBar
            Divider()
            if loading {
                Spacer(); ProgressView(); Spacer()
            } else if let errorMessage {
                Spacer(); InlineErrorBanner(message: errorMessage).padding(); Spacer()
            } else if visibleFiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(visibleFiles) { file in
                        fileRow(file)
                    }
                }
                .listStyle(.inset)
                .onDrop(of: [UTType.fileURL], isTargeted: $isBrowserDropTargeted) { providers in
                    handleDrop(providers: providers, destination: currentPath)
                }
            }
            Divider()
            footerBar
        }
        .overlay {
            if isBrowserDropTargeted {
                dropHintOverlay
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !uploads.isEmpty {
                UploadProgressOverlay(uploads: uploads)
                    .padding(16)
            }
        }
        .sheet(item: $editingFile) { file in
            FileEditorView(server: server, file: file)
        }
        .sheet(isPresented: $showingNewFileSheet) { newItemSheet(isFolder: false) }
        .sheet(isPresented: $showingNewFolderSheet) { newItemSheet(isFolder: true) }
        .sheet(item: $renamingFile) { file in
            renameSheet(file: file)
        }
        .task { await load() }
        // Persist wherever the user navigates to, per-server, so leaving this tab
        // (Files is torn down and rebuilt when you switch tabs) and coming back
        // reopens where you left off instead of snapping back to the home dir.
        .onChange(of: currentPath) { _, newValue in
            FileBrowserPathStore.save(newValue, for: server)
        }
    }

    // MARK: - Toolbar

    var toolbar: some View {
        HStack(spacing: 12) {
            Button { goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(pathHistory.isEmpty)

            Button { goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(currentPath == "/")

            Spacer()

            Button { showHiddenFiles.toggle() } label: {
                Image(systemName: showHiddenFiles ? "eye" : "eye.slash")
            }
            .help(showHiddenFiles ? "Hide dotfiles" : "Show dotfiles")

            Button { openInTerminal(currentPath) } label: { Image(systemName: "terminal") }
                .help("Open this folder in Terminal")

            Button { pickFilesToUpload() } label: { Image(systemName: "square.and.arrow.up") }
                .help("Upload files or folders…")
            Button { showingNewFolderSheet = true } label: { Image(systemName: "folder.badge.plus") }
                .help("New folder")
            Button { showingNewFileSheet = true } label: { Image(systemName: "doc.badge.plus") }
                .help("New file")
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }

    // MARK: - Breadcrumb

    private struct PathSegment: Identifiable {
        let id = UUID()
        let label: String
        let path: String
    }

    private func pathSegments(_ path: String) -> [PathSegment] {
        var segments: [PathSegment] = [PathSegment(label: "/", path: "/")]
        let parts = path.split(separator: "/").map(String.init)
        var accumulated = ""
        for part in parts {
            accumulated += "/" + part
            segments.append(PathSegment(label: part, path: accumulated))
        }
        return segments
    }

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let segments = pathSegments(currentPath)
                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    Button(segment.label) { navigateToBreadcrumb(segment.path) }
                        .buttonStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(index == segments.count - 1 ? Color.primary : Color.accentColor)
                    if index < segments.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Theme.surface)
    }

    private func navigateToBreadcrumb(_ path: String) {
        guard path != currentPath else { return }
        pathHistory.append(currentPath)
        currentPath = path
        Task { await load() }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 6) {
            let dirCount = visibleFiles.filter { $0.isDirectory }.count
            let fileCount = visibleFiles.count - dirCount
            Text(summaryText(dirCount: dirCount, fileCount: fileCount))
            if !showHiddenFiles && hiddenCount > 0 {
                Text("· \(hiddenCount) hidden").foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.surface)
    }

    private func summaryText(dirCount: Int, fileCount: Int) -> String {
        if dirCount == 0 && fileCount == 0 { return "Empty folder" }
        var parts: [String] = []
        if dirCount > 0 { parts.append("\(dirCount) folder\(dirCount == 1 ? "" : "s")") }
        if fileCount > 0 { parts.append("\(fileCount) file\(fileCount == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray").font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(showHiddenFiles || hiddenCount == 0 ? "This folder is empty" : "No visible files")
                .foregroundStyle(.secondary)
            if !showHiddenFiles && hiddenCount > 0 {
                Button("Show \(hiddenCount) hidden item\(hiddenCount == 1 ? "" : "s")") {
                    showHiddenFiles = true
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rows

    @ViewBuilder
    private func fileRow(_ file: RemoteFile) -> some View {
        let icon = iconFor(file)
        HStack {
            if isExtracting.contains(file.path) {
                ProgressView().controlSize(.small).frame(width: 22)
            } else {
                Image(systemName: icon.symbol)
                    .foregroundStyle(file.isDirectory ? Color.primary : icon.tint)
                    .frame(width: 22)
            }
            Text(file.name)
            if file.isSymlink {
                Image(systemName: "arrow.turn.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .help("Symbolic link")
            }
            Spacer()
            if let modified = file.modifiedAt {
                Text(modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !file.isDirectory {
                Text(formatSize(file.sizeBytes)).font(.caption).foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }
            Text(file.permissions).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .background(
            targetedPaths.contains(file.path) ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .onTapGesture(count: 2) {
            if file.isDirectory { navigate(to: file.path) } else { editingFile = file }
        }
        .contextMenu {
            if file.isDirectory {
                Button("Open") { navigate(to: file.path) }
                Button("Open in Terminal") { openInTerminal(file.path) }
            } else {
                let editable = FileKind.detect(name: file.name, sizeBytes: file.sizeBytes).isEditable
                Button(editable ? "Edit" : "Preview") { editingFile = file }
                Button("Download…") { downloadFile(file) }
                if isArchive(file.name) {
                    Button("Extract Here") { Task { await extractArchive(file) } }
                }
            }
            Button("Rename…") {
                renameText = file.name
                renamingFile = file
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task {
                    try? await SFTPService.shared.delete(server, path: file.path, isDirectory: file.isDirectory)
                    await load()
                }
            }
        }
        .modifier(DirectoryDropModifier(
            isDirectory: file.isDirectory,
            path: file.path,
            targetedPaths: $targetedPaths,
            onDrop: { providers in handleDrop(providers: providers, destination: file.path) }
        ))
    }

    private var dropHintOverlay: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.accentColor, lineWidth: 3)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down.on.square")
                        .font(.system(size: 34))
                    Text("Drop to upload to \(currentPath)")
                        .font(.callout.weight(.medium))
                }
                .foregroundStyle(Color.accentColor)
            )
            .allowsHitTesting(false)
            .padding(8)
    }

    // MARK: - New file/folder sheet

    func newItemSheet(isFolder: Bool) -> some View {
        VStack(spacing: 16) {
            Text(isFolder ? "New Folder" : "New File").font(.headline)
            TextField("Name", text: $newItemName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            HStack {
                Button("Cancel") {
                    newItemName = ""
                    if isFolder { showingNewFolderSheet = false } else { showingNewFileSheet = false }
                }
                Spacer()
                Button("Create") {
                    Task {
                        let path = SFTPService.joinPath(currentPath, newItemName)
                        if isFolder {
                            try? await SFTPService.shared.createDirectory(server, path: path)
                        } else {
                            try? await SFTPService.shared.createFile(server, path: path)
                        }
                        newItemName = ""
                        showingNewFolderSheet = false
                        showingNewFileSheet = false
                        await load()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newItemName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    // MARK: - Rename sheet

    func renameSheet(file: RemoteFile) -> some View {
        VStack(spacing: 16) {
            Text("Rename").font(.headline)
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
                .onSubmit { Task { await performRename(file) } }
            HStack {
                Button("Cancel") { renamingFile = nil }
                Spacer()
                Button("Rename") { Task { await performRename(file) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(renameText.isEmpty || renameText == file.name)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    private func performRename(_ file: RemoteFile) async {
        let parent = (file.path as NSString).deletingLastPathComponent
        let newPath = parent.isEmpty ? "/" + renameText : SFTPService.joinPath(parent, renameText)
        do {
            try await SFTPService.shared.rename(server, from: file.path, to: newPath)
        } catch {
            errorMessage = error.localizedDescription
        }
        renamingFile = nil
        await load()
    }

    // MARK: - Download

    private func downloadFile(_ file: RemoteFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.canCreateDirectories = true
        panel.title = "Save \"\(file.name)\""
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await SFTPService.shared.downloadFile(server, remotePath: file.path, to: url, timeout: 3600)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Extract archive

    private func isArchive(_ name: String) -> Bool {
        let lower = name.lowercased()
        let compoundSuffixes = [".tar.gz", ".tgz", ".tar.bz2", ".tbz2", ".tar.xz"]
        if compoundSuffixes.contains(where: { lower.hasSuffix($0) }) { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["zip", "tar", "gz", "bz2"].contains(ext)
    }

    private func extractArchive(_ file: RemoteFile) async {
        isExtracting.insert(file.path)
        do {
            try await SFTPService.shared.extractArchive(server, path: file.path)
        } catch {
            errorMessage = error.localizedDescription
        }
        isExtracting.remove(file.path)
        await load()
    }

    // MARK: - Open in Terminal

    /// Switches to this server's Terminal tab and `cd`s its already-running SSH
    /// session to the given remote path — the terminal session persists in the
    /// background even while a different tab is showing, so this is instant.
    private func openInTerminal(_ path: String) {
        store.pendingTab = .terminal
        TerminalSessionManager.shared.cd(to: path, on: server)
    }

    // MARK: - Upload (toolbar picker)

    private func pickFilesToUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.title = "Upload to \(currentPath)"
        guard panel.runModal() == .OK else { return }
        uploadURLs(panel.urls, to: currentPath)
    }

    // MARK: - Upload (drag & drop)

    private func handleDrop(providers: [NSItemProvider], destination: String) -> Bool {
        let candidates = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !candidates.isEmpty else { return false }

        Task {
            var urls: [URL] = []
            for provider in candidates {
                if let url = await FileBrowserView.loadFileURL(provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            uploadURLs(urls, to: destination)
        }
        return true
    }

    private static func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var result: URL?
                if let data = item as? Data {
                    result = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    result = url
                } else if let nsurl = item as? NSURL {
                    result = nsurl as URL
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func uploadURLs(_ urls: [URL], to destination: String) {
        for url in urls {
            let task = UploadTask(name: url.lastPathComponent)
            uploads.append(task)
            let taskID = task.id

            Task {
                do {
                    try await SFTPService.shared.uploadItem(server, localURL: url, remoteDir: destination)
                    updateUpload(taskID, status: .done)
                } catch {
                    updateUpload(taskID, status: .failed(error.localizedDescription))
                }
                if destination == currentPath {
                    await load()
                }
                scheduleUploadCleanup()
            }
        }
    }

    private func updateUpload(_ id: UUID, status: UploadTask.Status) {
        guard let idx = uploads.firstIndex(where: { $0.id == id }) else { return }
        uploads[idx].status = status
    }

    private func scheduleUploadCleanup() {
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            uploads.removeAll { task in
                if case .done = task.status { return true }
                return false
            }
        }
    }

    // MARK: - Navigation

    func navigate(to path: String) {
        pathHistory.append(currentPath)
        currentPath = path
        Task { await load() }
    }

    func goBack() {
        guard let prev = pathHistory.popLast() else { return }
        currentPath = prev
        Task { await load() }
    }

    func goUp() {
        let parent = (currentPath as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            files = try await SFTPService.shared.list(server, path: currentPath)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    // MARK: - Icons

    private func iconFor(_ file: RemoteFile) -> (symbol: String, tint: Color) {
        if file.isDirectory { return ("folder.fill", .primary) }
        if isArchive(file.name) { return ("doc.zipper", .orange) }
        switch FileKind.detect(name: file.name, sizeBytes: file.sizeBytes) {
        case .code: return ("chevron.left.forwardslash.chevron.right", .blue)
        case .plainText: return ("doc.text", .secondary)
        case .image: return ("photo", .green)
        case .audio: return ("waveform", .purple)
        case .video: return ("play.rectangle.fill", .pink)
        case .pdf: return ("doc.richtext", .red)
        case .unsupported: return ("doc", .secondary)
        }
    }

    func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Remembers the last folder each server's file browser was showing, so switching away
/// from the Files tab and back (which tears down and recreates FileBrowserView) restores
/// where the user left off instead of resetting to the home directory. Backed by
/// UserDefaults, so it also survives quitting and relaunching the app.
enum FileBrowserPathStore {
    static func lastPath(for server: Server) -> String? {
        UserDefaults.standard.string(forKey: key(for: server))
    }

    static func save(_ path: String, for server: Server) {
        UserDefaults.standard.set(path, forKey: key(for: server))
    }

    private static func key(for server: Server) -> String {
        "vpsmanager.filebrowser.lastpath.\(server.id.uuidString)"
    }
}

/// Attaches a per-row drop target (only meaningful for directories) so dropping files
/// directly onto a folder uploads into that folder rather than the currently-open one.
private struct DirectoryDropModifier: ViewModifier {
    let isDirectory: Bool
    let path: String
    @Binding var targetedPaths: Set<String>
    let onDrop: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if isDirectory {
            content.onDrop(of: [UTType.fileURL], isTargeted: Binding(
                get: { targetedPaths.contains(path) },
                set: { newValue in
                    if newValue { targetedPaths.insert(path) } else { targetedPaths.remove(path) }
                }
            ), perform: onDrop)
        } else {
            content
        }
    }
}