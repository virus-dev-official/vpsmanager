import SwiftUI

struct PM2DashboardView: View {
    let server: Server
    @EnvironmentObject var store: AppStore
    @State private var statuses: [PM2ProcessStatus] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var selectedProcess: PM2ProcessStatus?
    @State private var showingWizard = false
    @State private var refreshTimer: Timer?

    var body: some View {
        VStack(spacing: 0) {
            SectionTopBar(title: "\(statuses.count) processes", systemImage: "bolt.horizontal.circle", onRefresh: { Task { await refresh() } }) {
                Button { showingWizard = true } label: { Label("New PM2 App", systemImage: "plus") }
            }
            Divider()

            if loading {
                Spacer(); ProgressView(); Spacer()
            } else if let errorMessage {
                Spacer()
                InlineErrorBanner(message: errorMessage)
                    .padding(24)
                    .frame(maxWidth: 520)
                Spacer()
            } else if statuses.isEmpty {
                ContentUnavailableView("No PM2 Processes", systemImage: "bolt.horizontal.circle",
                    description: Text("Nothing is currently running under pm2 on this server."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                        ForEach(statuses) { proc in
                            PM2StatusCard(proc: proc, server: server) {
                                selectedProcess = proc
                            } onAction: { action in
                                Task { await perform(action, on: proc) }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $selectedProcess) { proc in
            PM2LogsView(server: server, processName: proc.name)
        }
        .sheet(isPresented: $showingWizard) {
            PM2WizardView(server: server) { config in
                store.pm2Configs.append(config)
                showingWizard = false
                Task { await refresh() }
            }
        }
        .task {
            await refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { await refresh() }
            }
        }
        .onDisappear { refreshTimer?.invalidate() }
    }

    func refresh() async {
        do {
            statuses = try await PM2Service.shared.fetchStatuses(server)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    enum Action { case restart, stop, delete }
    func perform(_ action: Action, on proc: PM2ProcessStatus) async {
        do {
            switch action {
            case .restart: try await PM2Service.shared.restart(server, name: proc.name)
            case .stop: try await PM2Service.shared.stop(server, name: proc.name)
            case .delete: try await PM2Service.shared.delete(server, name: proc.name)
            }
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PM2StatusCard: View {
    let proc: PM2ProcessStatus
    let server: Server
    var onViewLogs: () -> Void
    var onAction: (PM2DashboardView.Action) -> Void

    var runState: RunState {
        switch proc.status {
        case "online": return .running
        case "stopped": return .stopped
        case "errored": return .failed
        default: return .unknown
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(systemImage: "bolt.horizontal.circle", tone: runState == .failed ? Theme.danger : Theme.accent)
                Text(proc.name).font(.headline).lineLimit(1)
                Spacer()
                StatusPill(state: runState)
            }
            HStack(spacing: 16) {
                StatReadout(label: "CPU", value: "\(Int(proc.cpu))%")
                StatReadout(label: "RAM", value: "\(Int(proc.memoryMB)) MB")
                StatReadout(label: "Restarts", value: "\(proc.restarts)")
            }
            Text("Up \(formatUptime(proc.uptimeMs))").font(.caption).foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Logs", action: onViewLogs).buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Menu {
                    Button("Restart") { onAction(.restart) }
                    Button("Stop") { onAction(.stop) }
                    Button("Delete", role: .destructive) { onAction(.delete) }
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
        }
        .cardBackground()
    }

    func formatUptime(_ ms: Double) -> String {
        let seconds = Int(ms / 1000)
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}