import SwiftUI

struct SystemdView: View {
    let server: Server
    @EnvironmentObject var store: AppStore
    @State private var units: [SystemdUnitStatus] = []
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var selectedUnit: SystemdUnitStatus?
    @State private var showingDiscover = false
    @State private var busyUnits: Set<String> = []
    @State private var actionError: ActionError?

    struct ActionError: Identifiable {
        let id = UUID()
        let message: String
        let copyableFix: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionTopBar(title: "\(units.count) tracked services", systemImage: "gearshape.2", onRefresh: { Task { await load() } }) {
                Button { showingDiscover = true } label: { Label("Discover", systemImage: "plus.magnifyingglass") }
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
            } else if units.isEmpty {
                Spacer()
                ContentUnavailableView("No Services Tracked", systemImage: "gearshape.2",
                    description: Text("Tap Discover to find and track services running on \(server.nickname), like custom app services or timers."))
                Spacer()
            } else {
                ScrollView {
                    if let actionError {
                        InlineErrorBanner(message: actionError.message, copyableFix: actionError.copyableFix)
                            .padding([.horizontal, .top], 16)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                        ForEach(units) { unit in
                            SystemdUnitCard(
                                unit: unit,
                                isBusy: busyUnits.contains(unit.name),
                                onLogs: { selectedUnit = unit },
                                onAction: { action in Task { await perform(action, on: unit) } },
                                onStopTracking: {
                                    store.removeSystemdUnit(unit.name, for: server.id)
                                    Task { await load() }
                                }
                            )
                        }
                    }
                    .padding(16)
                }
            }
        }
        .sheet(item: $selectedUnit) { unit in
            SystemdJournalView(server: server, unitName: unit.name)
        }
        .sheet(isPresented: $showingDiscover) {
            SystemdDiscoverView(server: server, alreadyTracked: store.systemdUnits(for: server.id)) { picked in
                store.addSystemdUnits(picked, for: server.id)
                Task { await load() }
            }
        }
        .task { await load() }
    }

    enum UnitAction { case start, stop, restart, enable, disable }

    func perform(_ action: UnitAction, on unit: SystemdUnitStatus) async {
        busyUnits.insert(unit.name)
        actionError = nil
        do {
            switch action {
            case .start: try await SystemdService.shared.start(server, unit: unit.name)
            case .stop: try await SystemdService.shared.stop(server, unit: unit.name)
            case .restart: try await SystemdService.shared.restart(server, unit: unit.name)
            case .enable: try await SystemdService.shared.enable(server, unit: unit.name)
            case .disable: try await SystemdService.shared.disable(server, unit: unit.name)
            }
        } catch {
            actionError = ActionError(message: error.localizedDescription, copyableFix: extractSudoFixCommand(from: error))
        }
        busyUnits.remove(unit.name)
        await load()
    }

    func load() async {
        loading = units.isEmpty // only show the big spinner on first load; refreshes stay quiet
        errorMessage = nil
        do {
            units = try await SystemdService.shared.statuses(server, units: store.systemdUnits(for: server.id))
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}

private struct SystemdUnitCard: View {
    let unit: SystemdUnitStatus
    let isBusy: Bool
    var onLogs: () -> Void
    var onAction: (SystemdView.UnitAction) -> Void
    var onStopTracking: () -> Void

    var isTimer: Bool { unit.name.hasSuffix(".timer") }

    var displayName: String {
        unit.name.hasSuffix(".service") ? String(unit.name.dropLast(8)) : unit.name
    }

    var runState: RunState {
        unit.activeState == "failed" ? .failed : (unit.activeState == "active" ? .running : .stopped)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(systemImage: isTimer ? "clock" : "gearshape.2", tone: runState == .failed ? Theme.danger : Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(.headline, design: .monospaced))
                        .lineLimit(1)
                    Text(unit.subState)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(state: runState)
            }

            Label(unit.enabled ? "Enabled at boot" : "Not enabled", systemImage: unit.enabled ? "checkmark.circle" : "circle.dashed")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button("Logs", action: onLogs)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Spacer()
                Menu {
                    Button("Start") { onAction(.start) }
                    Button("Stop") { onAction(.stop) }
                    Button("Restart") { onAction(.restart) }
                    Divider()
                    Button(unit.enabled ? "Disable at Boot" : "Enable at Boot") {
                        onAction(unit.enabled ? .disable : .enable)
                    }
                    Divider()
                    Button("Stop Tracking", role: .destructive, action: onStopTracking)
                } label: {
                    Label("Actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 26)
            }
        }
        .cardBackground()
        .busyOverlay(isBusy)
    }
}
