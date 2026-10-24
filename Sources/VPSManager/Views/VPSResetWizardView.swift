import SwiftUI

struct VPSResetWizardView: View {
    let group: ServerGroup
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var rootServer: Server?
    @State private var hostInfo: VPSHostInfo?
    @State private var loading = true
    @State private var resetting = false
    @State private var finished = false
    @State private var armed = false
    @State private var typedConfirmation = ""
    @State private var log = ""
    @State private var errorMessage: String?

    private var expectedConfirmation: String { "RESET \(group.host)" }

    /// `group` is a snapshot from when the sheet opened; this reflects servers
    /// added since (e.g. by Enable Key-Only Root Login).
    private var liveGroup: ServerGroup {
        store.serverGroups.first { $0.id == group.id } ?? group
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reset VPS").font(.title2.bold())
                    Text("\(group.title) · \(group.servers.count) saved SSH entr\(group.servers.count == 1 ? "y" : "ies")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Done" : "Close") { dismiss() }
                    .disabled(resetting)
            }
            .padding(20)
            Divider()

            if !liveGroup.servers.contains(where: { $0.user == "root" }) {
                RootLoginRequiredView(group: liveGroup, action: "Resetting")
            } else if loading {
                Spacer()
                ProgressView("Checking root access and Linux host…")
                Spacer()
            } else {
                Form {
                    if let hostInfo {
                        Section("Host preflight passed") {
                            LabeledContent("OS", value: "\(hostInfo.distribution) \(hostInfo.version)")
                            LabeledContent("Architecture", value: hostInfo.architecture)
                            LabeledContent("Root SSH", value: rootServer?.sshTarget ?? "")
                            LabeledContent("Other local users to remove", value: hostInfo.nonRootUsers.isEmpty ? "None" : hostInfo.nonRootUsers.joined(separator: ", "))
                        }
                        Section("This reset will") {
                            Text("Remove every non-root user and its home, clear root's home except /root/.ssh, remove application directories and common database/container data, remove custom app service units, and disable common app/database services.")
                            Text("The installed Linux OS and packages, root account, root SSH keys, SSH daemon configuration, hostname, and network identity are retained. The app's projects, PM2 configs, tunnels, and tracked units for this host will also be removed.")
                                .foregroundStyle(.secondary)
                        }
                        Section("Confirm whole-host reset") {
                            TextField("Type \(expectedConfirmation)", text: $typedConfirmation)
                            Text("This is irreversible. Only root SSH access is guaranteed to remain.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    } else if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red)
                    }

                    if let errorMessage, hostInfo != nil {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                    if !log.isEmpty {
                        ScrollView {
                            Text(log)
                                .font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(height: 100)
                    }
                }
                .formStyle(.grouped)

                HStack {
                    Spacer()
                    if resetting {
                        ProgressView("Resetting the entire VPS…")
                            .controlSize(.small)
                    } else if hostInfo != nil && !finished {
                        if armed {
                            Button("Erase VPS Data", role: .destructive) {
                                Task { await reset() }
                            }
                            .disabled(typedConfirmation != expectedConfirmation)
                        } else {
                            Button("Review Reset…") { armed = true }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 620, height: 620)
        .task(id: liveGroup.servers.contains(where: { $0.user == "root" })) {
            guard liveGroup.servers.contains(where: { $0.user == "root" }) else { return }
            await loadPreflight()
        }
    }

    private func loadPreflight() async {
        do {
            let result = try await ServerLifecycleService.shared.preflight(liveGroup)
            rootServer = result.rootServer
            hostInfo = result.info
        } catch {
            errorMessage = error.localizedDescription
        }
        loading = false
    }

    private func reset() async {
        guard let rootServer else { return }
        resetting = true
        errorMessage = nil
        log = "Resetting data on \(group.host)…\n"
        defer { resetting = false }
        do {
            try await ServerLifecycleService.shared.reset(rootServer)
            let serverIDs = Set(group.servers.map(\.id))
            store.removeData(for: serverIDs)
            store.servers.removeAll { serverIDs.contains($0.id) && $0.id != rootServer.id }
            store.selectedServerID = rootServer.id
            store.pendingServerID = rootServer.id
            log += "Reset complete. Root SSH access and host networking were preserved.\n"
            armed = false
            typedConfirmation = ""
            finished = true
        } catch {
            errorMessage = error.localizedDescription
            log += "\n\(error.localizedDescription)\n"
        }
    }
}

/// Shown instead of the reset / transfer wizards when the host has no saved
/// root login, explaining why root is required and offering to enable it.
struct RootLoginRequiredView: View {
    let group: ServerGroup
    let action: String
    @EnvironmentObject private var store: AppStore
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ContentUnavailableView {
            Label("Needs a Root Login", systemImage: "lock.shield")
        } description: {
            Text("""
            \(action) a whole VPS removes every non-root user — including the accounts VPS Manager \
            connects as — so it has to run as root. None of the saved logins for \(group.title) is root.

            VPS Manager can turn on key-only root login for you through \(group.servers.first?.user ?? "your account")'s \
            sudo: your existing SSH key is allowed for root, root password login stays off.
            """)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: 460)
        } actions: {
            VStack(spacing: 10) {
                Button {
                    enable()
                } label: {
                    if working { ProgressView().controlSize(.small) } else { Text("Enable Key-Only Root Login") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || group.servers.isEmpty)
                if let error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func enable() {
        guard let via = group.servers.first else { return }
        working = true
        Task {
            defer { working = false }
            do {
                let root = try await ServerSetupService.enableRootLogin(via: via)
                store.servers.append(root)   // the sheet switches to the reset preflight
            } catch {
                self.error = extractSudoFixCommand(from: error).map { "Needs passwordless sudo. Run on the server: \($0)" }
                    ?? error.localizedDescription
            }
        }
    }
}
