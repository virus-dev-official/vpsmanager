import SwiftUI

/// Docker tab: containers (with live CPU / memory) and images.
struct DockerView: View {
    let server: Server
    @Environment(\.openServerTab) private var openServerTab

    enum Section: String, CaseIterable, Identifiable {
        case containers = "Containers", images = "Images"
        var id: String { rawValue }
    }

    @State private var section: Section = .containers
    @State private var availability: DockerService.Availability?
    @State private var containers: [DockerContainer] = []
    @State private var images: [DockerImage] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var busyIDs: Set<String> = []
    @State private var logsFor: DockerContainer?
    @State private var removeTarget: DockerContainer?
    @State private var removeImageTarget: DockerImage?
    @State private var confirmPrune = false
    @State private var notice: String?
    @State private var onlyRunning = false

    private var visibleContainers: [DockerContainer] {
        onlyRunning ? containers.filter(\.isRunning) : containers
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionTopBar(title: topTitle, systemImage: "shippingbox", onRefresh: { Task { await load() } }) {
                if availability == .available {
                    Button {
                        confirmPrune = true
                    } label: {
                        Label("Clean Up", systemImage: "sparkles")
                    }
                    .help("docker system prune: remove stopped containers, dangling images and unused networks")
                }
            }

            if availability == .notInstalled {
                ContentUnavailableView("Docker Isn't Installed", systemImage: "shippingbox",
                                       description: Text("Install Docker Engine on \(server.nickname) to manage containers here."))
                    .frame(maxHeight: .infinity)
            } else if availability == .noPermission {
                ContentUnavailableView {
                    Label("No Access to Docker", systemImage: "lock")
                } description: {
                    Text("\(server.user) can't talk to the Docker daemon. Add the user to the docker group, then reconnect:")
                } actions: {
                    Text("sudo usermod -aG docker \(server.user)")
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Picker("", selection: $section) {
                                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                            Spacer()
                            if section == .containers {
                                Toggle("Only running", isOn: $onlyRunning)
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                            }
                        }
                        if let errorMessage {
                            InlineErrorBanner(message: errorMessage, copyableFix: nil)
                        }
                        if let notice {
                            Label(notice, systemImage: "checkmark.circle.fill")
                                .font(.callout)
                                .foregroundStyle(Theme.success)
                        }
                        if loading && containers.isEmpty && images.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(30)
                        } else if section == .containers {
                            containersTable
                        } else {
                            imagesTable
                        }
                    }
                    .padding(22)
                    .frame(maxWidth: 1200)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Theme.canvas)
        .task { await load() }
        .sheet(item: $logsFor) { container in
            LiveLogView(server: server, title: "docker logs \(container.name)",
                        command: DockerService.shared.logsCommand(for: container))
        }
        .confirmationDialog("Remove container \(removeTarget?.name ?? "")?", isPresented: Binding(
            get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let target = removeTarget { act(.remove, target) }
                removeTarget = nil
            }
        } message: {
            Text("The container is stopped and deleted. Named volumes are kept.")
        }
        .confirmationDialog("Remove image \(removeImageTarget?.displayName ?? "")?", isPresented: Binding(
            get: { removeImageTarget != nil }, set: { if !$0 { removeImageTarget = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Image", role: .destructive) {
                guard let image = removeImageTarget else { return }
                removeImageTarget = nil
                Task {
                    do { try await DockerService.shared.removeImage(image, server: server) } catch { errorMessage = error.localizedDescription }
                    await load()
                }
            }
        }
        .confirmationDialog("Clean up Docker on \(server.nickname)?", isPresented: $confirmPrune, titleVisibility: .visible) {
            Button("Clean Up", role: .destructive) {
                Task {
                    do {
                        let summary = try await DockerService.shared.prune(server)
                        notice = summary.isEmpty ? "Cleaned up." : summary
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                    await load()
                }
            }
        } message: {
            Text("Removes all stopped containers, dangling images, unused networks and build cache.")
        }
    }

    private var topTitle: String {
        let running = containers.filter(\.isRunning).count
        return "\(running) running · \(containers.count) container\(containers.count == 1 ? "" : "s") · \(images.count) image\(images.count == 1 ? "" : "s")"
    }

    // MARK: - Containers

    private var containersTable: some View {
        VStack(spacing: 0) {
            tableHeader(["Name", "Status", "CPU", "Memory", "Ports", "Actions"], widths: [nil, 120, 56, 84, -1, 156])
            if visibleContainers.isEmpty {
                Text(containers.isEmpty ? "No containers on this server." : "No running containers.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            }
            ForEach(visibleContainers) { container in
                Rectangle().fill(Theme.stroke).frame(height: 1)
                containerRow(container)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func containerRow(_ c: DockerContainer) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: c.isRunning ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(c.isRunning ? Theme.success : c.state == "restarting" ? Theme.warning : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Text(c.image).font(.caption.monospaced()).foregroundStyle(Theme.accent).lineLimit(1)
                }
            }
            .frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(c.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .leading)
            Text(c.cpu ?? "—").font(.caption.monospacedDigit()).frame(width: 56, alignment: .leading)
            Text(c.memory.map { $0.components(separatedBy: " / ").first ?? $0 } ?? "—")
                .font(.caption.monospacedDigit()).lineLimit(1).frame(width: 84, alignment: .leading)
            Text(c.ports.isEmpty ? "—" : c.ports)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2).frame(minWidth: 60, maxWidth: 180, alignment: .leading)
                .help(c.ports)
            HStack(spacing: 2) {
                if c.isRunning {
                    rowButton("stop.fill", "Stop") { act(.stop, c) }
                    rowButton("arrow.clockwise", "Restart") { act(.restart, c) }
                } else {
                    rowButton("play.fill", "Start") { act(.start, c) }
                }
                rowButton("doc.plaintext", "Logs") { logsFor = c }
                rowButton("terminal", "Open a shell inside") { openShell(c) }
                    .disabled(!c.isRunning)
                rowButton("trash", "Remove", tint: Theme.danger) { removeTarget = c }
            }
            .frame(width: 156, alignment: .leading)
            .busyOverlay(busyIDs.contains(c.id))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    // MARK: - Images

    private var imagesTable: some View {
        VStack(spacing: 0) {
            tableHeader(["Image", "ID", "Size", "Created", ""], widths: [nil, 120, 90, 130, 40])
            if images.isEmpty {
                Text("No images.").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
            }
            ForEach(images) { image in
                Rectangle().fill(Theme.stroke).frame(height: 1)
                HStack(spacing: 12) {
                    Text(image.displayName).font(.callout.weight(.medium).monospaced()).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(image.id).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                    Text(image.size).font(.caption.monospacedDigit()).frame(width: 90, alignment: .leading)
                    Text(image.created).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .leading)
                    rowButton("trash", "Remove image", tint: Theme.danger) { removeImageTarget = image }
                        .frame(width: 40)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.stroke))
    }

    // MARK: - Helpers

    private func tableHeader(_ titles: [String], widths: [CGFloat?]) -> some View {
        HStack(spacing: 12) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if let width = widths[index], width < 0 {
                    Text(title).frame(minWidth: 60, maxWidth: 180, alignment: .leading)
                } else if let width = widths[index] {
                    Text(title).frame(width: width, alignment: .leading)
                } else {
                    Text(title).frame(minWidth: 90, maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Theme.surfaceAlt)
    }

    private func rowButton(_ symbol: String, _ help: String, tint: Color = Theme.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(width: 25, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func act(_ action: DockerService.ContainerAction, _ container: DockerContainer) {
        busyIDs.insert(container.id)
        Task {
            defer { busyIDs.remove(container.id) }
            do {
                try await DockerService.shared.perform(action, on: container, server: server)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            await load()
        }
    }

    /// Opens a new terminal tab already exec'd into the container.
    private func openShell(_ container: DockerContainer) {
        let manager = TerminalSessionManager.shared
        let session = manager.newSession(on: server)
        let id = shellQuoted(container.id)
        session.view.send(txt: "D=docker; docker ps -q >/dev/null 2>&1 || D='sudo docker'; $D exec -it \(id) sh -c 'command -v bash >/dev/null && exec bash || exec sh'\n")
        openServerTab(.terminal)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let (availability, list) = try await DockerService.shared.containers(server)
            self.availability = availability
            containers = list
            if availability == .available {
                images = try await DockerService.shared.images(server)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
