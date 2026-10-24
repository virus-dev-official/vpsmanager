import SwiftUI

/// Scans the server for tunnels/routes that already exist but were never created
/// through this app's wizard (e.g. set up by hand with a custom systemd unit and
/// config file, like a per-tunnel `cloudflared-<name>.service`). Lets the user pick
/// which ones to pull into the app so they show up in the dashboard going forward.
struct ImportTunnelsView: View {
    let server: Server
    var onImport: ([(CloudflareTunnel, [TunnelRoute])]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var loading = true
    @State private var discovered: [CloudflaredService.DiscoveredTunnel] = []
    @State private var selected: Set<String> = []
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Import Existing Tunnels").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(20)
            Divider()

            if loading {
                Spacer(); ProgressView("Scanning \(server.nickname) for tunnels…"); Spacer()
            } else if let errorMessage {
                Spacer(); Text(errorMessage).foregroundStyle(.red).padding(); Spacer()
            } else if discovered.isEmpty {
                ContentUnavailableView("Nothing Found", systemImage: "magnifyingglass",
                    description: Text("No tunnels via `cloudflared tunnel list` on this server."))
            } else {
                List(discovered, selection: $selected) { tunnel in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(tunnel.name).font(.headline)
                            if let unit = tunnel.systemdUnit {
                                Text(unit).font(.caption).padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(.quaternary, in: Capsule())
                            }
                        }
                        Text("config: \(tunnel.configPath)").font(.caption).foregroundStyle(.secondary)
                        if tunnel.routes.isEmpty {
                            Text("No ingress routes found in config").font(.caption.bold()).foregroundStyle(.secondary)
                        } else {
                            ForEach(tunnel.routes, id: \.hostname) { route in
                                Text("• \(route.hostname) → localhost:\(route.port.map(String.init) ?? "?")")
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .tag(tunnel.id)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text("\(selected.count) selected").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Import Selected") {
                    let toImport = discovered.filter { selected.contains($0.id) }.map { d -> (CloudflareTunnel, [TunnelRoute]) in
                        let tunnel = CloudflareTunnel(
                            serverID: server.id,
                            tunnelName: d.name,
                            tunnelID: d.tunnelID,
                            credentialsFile: "",
                            configPath: d.configPath,
                            systemdUnit: d.systemdUnit ?? "cloudflared"
                        )
                        let routes = d.routes.compactMap { r -> TunnelRoute? in
                            guard let port = r.port else { return nil }
                            return TunnelRoute(tunnelID: tunnel.id, hostname: r.hostname, localPort: port)
                        }
                        return (tunnel, routes)
                    }
                    onImport(toImport)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 560, height: 520)
        .task { await scan() }
    }

    func scan() async {
        loading = true
        errorMessage = nil
        do {
            discovered = try await CloudflaredService.shared.discoverExisting(server)
            selected = Set(discovered.map(\.id)) // pre-select everything found
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }
}