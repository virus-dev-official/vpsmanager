import SwiftUI

struct VPSMigrationWizardView: View {
    let sourceGroup: ServerGroup
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var destinationGroupID = ""
    @State private var preflight: VPSMigrationPreflight?
    @State private var checking = false
    @State private var transferring = false
    @State private var armed = false
    @State private var typedConfirmation = ""
    @State private var passphrase = ""
    @State private var passphraseConfirmation = ""
    @State private var log = ""
    @State private var errorMessage: String?
    @State private var finished = false

    private var destinationGroups: [ServerGroup] {
        store.serverGroups.filter { $0.id != sourceGroup.id }
    }

    private var destinationGroup: ServerGroup? {
        destinationGroups.first { $0.id == destinationGroupID }
    }

    private var sourceRoot: Server? {
        sourceGroup.servers.first { $0.user == "root" }
    }

    private var destinationRoot: Server? {
        destinationGroup?.servers.first { $0.user == "root" }
    }

    private var expectedConfirmation: String {
        "REPLACE \(destinationGroup?.host ?? "")"
    }

    private var canStart: Bool {
        preflight != nil &&
        passphrase.count >= 12 &&
        passphrase == passphraseConfirmation &&
        typedConfirmation == expectedConfirmation &&
        !transferring
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transfer VPS").font(.title2.bold())
                    Text("Source: \(sourceGroup.title)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(finished ? "Done" : "Close") { dismiss() }
                    .disabled(transferring)
            }
            .padding(20)
            Divider()

            Form {
                Section("Destination") {
                    Picker("Replace VPS", selection: $destinationGroupID) {
                        Text("Choose a host").tag("")
                        ForEach(destinationGroups) { group in
                            Text(group.title).tag(group.id)
                        }
                    }
                    .disabled(transferring || finished)
                    Text("Both host groups must contain a direct root SSH connection. The app validates root access and the root authorized_keys file before changing the destination.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(checking ? "Checking…" : "Check compatibility") {
                        Task { await checkCompatibility() }
                    }
                    .disabled(checking || transferring || destinationGroup == nil || sourceRoot == nil || destinationRoot == nil)
                }

                if let preflight {
                    Section("Compatibility check passed") {
                        LabeledContent("Linux", value: "\(preflight.source.distribution) \(preflight.source.version)")
                        LabeledContent("Architecture", value: preflight.source.architecture)
                        LabeledContent("Estimated source data", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: preflight.estimatedTransferBytes), countStyle: .file))
                        LabeledContent("Target free space", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: preflight.destination.rootFreeBytes), countStyle: .file))
                        Text("The transfer streams the live source filesystem through this Mac. It preserves the destination's SSH keys/configuration, root SSH identity, hostname, and network settings; source application/user state is transferred. It is not a provider disk snapshot or bootloader clone.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("For consistent databases and uploads, pause writes on the source before starting. The source is not stopped automatically.")
                            .font(.caption).foregroundStyle(.orange)
                    }

                    Section("Encrypt app settings") {
                        SecureField("Passphrase (at least 12 characters)", text: $passphrase)
                        SecureField("Confirm passphrase", text: $passphraseConfirmation)
                        Text("PM2 environment secrets are protected in an authenticated encrypted payload. The passphrase is not saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    Section("Confirm destination replacement") {
                        TextField("Type \(expectedConfirmation)", text: $typedConfirmation)
                        Text("The destination's existing user/application data will be removed before source files are transferred. If transfer or reboot verification fails, use your provider's console/rescue access.")
                            .font(.caption).foregroundStyle(.red)
                    }
                }

                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
                if !log.isEmpty {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 110)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                if transferring {
                    ProgressView("Transferring system state…")
                        .controlSize(.small)
                } else if finished {
                    Button("Done") { dismiss() }
                        .buttonStyle(.borderedProminent)
                } else if armed {
                    Button("Transfer and Replace Destination", role: .destructive) {
                        Task { await transfer() }
                    }
                    .disabled(!canStart)
                } else if preflight != nil {
                    Button("Review and Replace Destination…") { armed = true }
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .frame(width: 700, height: 700)
        .onChange(of: destinationGroupID) { _, _ in
            preflight = nil
            armed = false
            typedConfirmation = ""
            errorMessage = nil
        }
        .onAppear {
            if let group = destinationGroups.first(where: { $0.servers.contains(where: { $0.user == "root" }) }) {
                destinationGroupID = group.id
            }
        }
    }

    private func checkCompatibility() async {
        guard let destinationGroup else { return }
        checking = true
        errorMessage = nil
        preflight = nil
        do {
            preflight = try await ServerLifecycleService.shared.preflightTransfer(
                source: sourceGroup,
                destination: destinationGroup
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        checking = false
    }

    private func transfer() async {
        guard let destinationGroup,
              let sourceRoot,
              let destinationRoot else { return }
        transferring = true
        errorMessage = nil
        log = ""
        defer { transferring = false }

        do {
            let sourceIDs = Set(sourceGroup.servers.map(\.id))
            let payload = try store.exportTransferPayload(for: sourceIDs)
            let mapping = try makeDestinationMapping(sourceGroup: sourceGroup, destinationGroup: destinationGroup)
            let migratedPayload = try await ServerLifecycleService.shared.transfer(
                source: sourceRoot,
                destination: destinationRoot,
                passphrase: passphrase,
                appPayload: payload
            ) { line in
                log += line
            }

            let destinationIDs = Set(destinationGroup.servers.map(\.id))
            store.removeData(for: destinationIDs)
            store.servers.removeAll { destinationIDs.contains($0.id) && $0.id != destinationRoot.id }
            for migratedServer in mapping.newServers {
                store.servers.append(migratedServer)
            }
            try store.importTransferPayload(migratedPayload, serverIDMapping: mapping.ids)
            store.selectedServerID = destinationRoot.id
            store.pendingServerID = destinationRoot.id
            log += "App settings transferred and destination root SSH access verified.\n"
            finished = true
        } catch {
            errorMessage = error.localizedDescription
            log += "\n\(error.localizedDescription)\n"
        }
    }

    private func makeDestinationMapping(
        sourceGroup: ServerGroup,
        destinationGroup: ServerGroup
    ) throws -> (ids: [UUID: UUID], newServers: [Server]) {
        guard let destinationRoot else {
            throw NSError(domain: "VPSMigrationWizard", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The destination group must contain a root SSH connection."
            ])
        }
        var ids: [UUID: UUID] = [:]
        var copies: [Server] = []
        for source in sourceGroup.servers {
            if source.user == "root" {
                ids[source.id] = destinationRoot.id
                continue
            }
            var migrated = source
            migrated.id = UUID()
            migrated.host = destinationRoot.host
            migrated.port = destinationRoot.port
            migrated.nickname = "\(source.nickname) (migrated)"
            migrated.lastConnectedAt = nil
            copies.append(migrated)
            ids[source.id] = migrated.id
        }
        return (ids, copies)
    }
}
