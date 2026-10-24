import SwiftUI

struct TunnelWizardView: View {
    let server: Server
    var onComplete: (CloudflareTunnel, TunnelRoute) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore

    @State private var mode: Mode = .newTunnel
    @State private var existingTunnelChoice: CloudflareTunnel?
    @State private var newTunnelName = ""
    @State private var hostname = ""
    @State private var localPort = ""
    @State private var deploying = false
    @State private var log = ""
    @State private var errorMessage: String?
    @State private var done = false

    enum Mode { case newTunnel, existingTunnel }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New Route").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(20)
            Divider()

            Form {
                if !store.tunnels(for: server.id).isEmpty {
                    Picker("Tunnel", selection: $mode) {
                        Text("New tunnel").tag(Mode.newTunnel)
                        Text("Existing tunnel").tag(Mode.existingTunnel)
                    }
                    .pickerStyle(.segmented)
                }

                if mode == .newTunnel {
                    TextField("Tunnel name", text: $newTunnelName, prompt: Text("my-vps-1"))
                } else {
                    Picker("Existing tunnel", selection: $existingTunnelChoice) {
                        ForEach(store.tunnels(for: server.id)) { t in
                            Text(t.tunnelName).tag(Optional(t))
                        }
                    }
                }

                TextField("Domain / subdomain", text: $hostname, prompt: Text("api.example.com"))
                TextField("Local port", text: $localPort, prompt: Text("3000"))
                    #if os(macOS)
                    .textContentType(.none)
                    #endif

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }

                if !log.isEmpty {
                    ScrollView {
                        Text(log).font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                    .background(.black.opacity(0.85))
                    .foregroundStyle(Color(white: 0.85))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                if done {
                    Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                } else {
                    Button(deploying ? "Creating…" : "Create Route") {
                        Task { await createRoute() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(deploying || hostname.isEmpty || localPort.isEmpty || (mode == .newTunnel && newTunnelName.isEmpty) || (mode == .existingTunnel && existingTunnelChoice == nil))
                }
            }
            .padding(20)
        }
        .frame(width: 600, height: 560)
    }

    func createRoute() async {
        deploying = true
        errorMessage = nil
        defer { deploying = false }

        let tunnelName = mode == .newTunnel ? newTunnelName : (existingTunnelChoice?.tunnelName ?? "")
        guard let port = Int(localPort) else { errorMessage = "Invalid port"; return }

        do {
            let result = try await CloudflaredService.shared.createOrUpdateTunnelAndRoute(
                server: server,
                tunnelName: tunnelName,
                hostname: hostname,
                localPort: port,
                configPath: existingTunnelChoice?.configPath,
                systemdUnit: existingTunnelChoice?.systemdUnit,
                credentialsFile: existingTunnelChoice?.credentialsFile
            ) { line in log += line }

            let tunnel = existingTunnelChoice ?? CloudflareTunnel(
                serverID: server.id,
                tunnelName: tunnelName,
                tunnelID: result.tunnelID,
                credentialsFile: result.credentialsFile,
                configPath: result.configPath,
                systemdUnit: result.systemdUnit
            )
            let route = TunnelRoute(tunnelID: tunnel.id, hostname: hostname, localPort: port)
            done = true
            onComplete(tunnel, route)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}