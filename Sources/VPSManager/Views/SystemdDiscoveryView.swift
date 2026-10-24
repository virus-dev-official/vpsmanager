import SwiftUI

/// Lists every service + timer unit on the server so the user can pick which custom
/// ones to track, instead of typing each name by hand. Common OS-level units are
/// filtered out of the default view (toggleable) since they'd otherwise bury things
/// like `echo-api` or `echo-consolidation.timer` under dozens of systemd internals.
struct SystemdDiscoverView: View {
    let server: Server
    let alreadyTracked: [String]
    var onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var allUnits: [String] = []
    @State private var selected: Set<String> = []
    @State private var showNoise = false
    @State private var searchText = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Discover Services").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(20)
            Divider()

            HStack {
                TextField("Filter", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                Toggle("Show system-level units", isOn: $showNoise)
                    .toggleStyle(.checkbox)
            }
            .padding(12)
            Divider()

            if loading {
                Spacer(); ProgressView("Scanning \(server.nickname)…"); Spacer()
            } else if let errorMessage {
                Spacer(); Text(errorMessage).foregroundStyle(.red).padding(); Spacer()
            } else {
                List(filteredUnits, id: \.self, selection: $selected) { unit in
                    Text(unit.hasSuffix(".service") ? String(unit.dropLast(8)) : unit)
                        .font(.system(.body, design: .monospaced)).tag(unit)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Add Selected") {
                    onAdd(Array(selected))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 480, height: 560)
        .task { await load() }
    }

    private var filteredUnits: [String] {
        var units = allUnits.filter { !alreadyTracked.contains($0) }
        if !showNoise {
            units = units.filter { unit in !SystemdService.noisePrefixes.contains(where: { unit.hasPrefix($0) }) }
        }
        if !searchText.isEmpty {
            units = units.filter { $0.localizedCaseInsensitiveContains(searchText) }
        }
        return units
    }

    func load() async {
        loading = true
        errorMessage = nil
        do {
            allUnits = try await SystemdService.shared.discoverAllUnits(server)
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}