import SwiftUI
import AppKit

/// Network tab: what's listening on the server, and the ufw firewall in front of it.
struct NetworkView: View {
    let server: Server
    @ObservedObject private var forwards = PortForwardService.shared

    @State private var ports: [ListeningPort] = []
    @State private var firewall: FirewallStatus?
    @State private var loading = true
    @State private var errorMessage: String?
    @State private var firewallError: String?
    @State private var busy = false
    @State private var showLocalOnly = true
    @State private var showingAddRule = false
    @State private var ruleToDelete: FirewallRule?
    @State private var confirmDisable = false

    private var visiblePorts: [ListeningPort] {
        showLocalOnly ? ports : ports.filter { !$0.isLocalOnly }
    }

    var body: some View {
        VStack(spacing: 0) {
            SectionTopBar(title: "\(ports.count) listening socket\(ports.count == 1 ? "" : "s")", systemImage: "network",
                          onRefresh: { Task { await load() } }) {
                EmptyView()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let errorMessage {
                        InlineErrorBanner(message: errorMessage)
                    }
                    firewallCard
                    portsCard
                }
                .padding(22)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.canvas)
        .task { await load() }
        .sheet(isPresented: $showingAddRule) {
            AddFirewallRuleSheet(server: server) { await load() }
        }
        .confirmationDialog("Delete rule \(ruleToDelete?.number ?? 0)?", isPresented: Binding(
            get: { ruleToDelete != nil }, set: { if !$0 { ruleToDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete Rule", role: .destructive) {
                guard let rule = ruleToDelete else { return }
                run { try await NetworkService.shared.deleteRule(server, number: rule.number) }
                ruleToDelete = nil
            }
        } message: {
            if let rule = ruleToDelete, isSSHRule(rule) {
                Text("⚠️ This rule looks like it allows SSH (\(rule.target)). Removing it can lock VPS Manager — and you — out of this server.")
            } else {
                Text("\(ruleToDelete?.action ?? "") \(ruleToDelete?.target ?? "") from \(ruleToDelete?.from ?? "")")
            }
        }
        .confirmationDialog("Turn off the firewall?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Disable Firewall", role: .destructive) {
                run { try await NetworkService.shared.disable(server) }
            }
        } message: {
            Text("Every port that's listening on a public address becomes reachable from the internet.")
        }
    }

    // MARK: - Firewall

    private var firewallCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(systemImage: "shield.lefthalf.filled", tone: firewall?.active == true ? Theme.success : Theme.warning)
                Text("Firewall (ufw)").font(.headline)
                if let firewall, firewall.installed {
                    TintedPill(label: firewall.active ? "Active" : "Inactive", tint: firewall.active ? Theme.success : Theme.warning)
                }
                Spacer()
                if let firewall, firewall.installed {
                    Button {
                        showingAddRule = true
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    if firewall.active {
                        Button("Disable") { confirmDisable = true }
                            .buttonStyle(.bordered)
                    } else {
                        Button("Enable") {
                            run { try await NetworkService.shared.enable(server) }
                        }
                        .buttonStyle(.bordered)
                        .help("Allows SSH on port \(server.port) first, then turns ufw on")
                    }
                }
            }
            .controlSize(.small)
            .busyOverlay(busy)

            if let firewallError {
                InlineErrorBanner(message: firewallError, copyableFix: nil)
            } else if let firewall {
                if !firewall.installed {
                    Text("ufw isn't installed on this server. Install it with `sudo apt install ufw` to manage firewall rules here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if firewall.rules.isEmpty {
                    Text(firewall.active ? "Active with no rules — everything incoming is blocked by default policy." : "No rules yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(firewall.rules) { rule in
                            HStack(spacing: 12) {
                                Text("\(rule.number)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(rule.target)
                                    .font(.callout.monospaced().weight(.medium))
                                    .frame(minWidth: 140, alignment: .leading)
                                TintedPill(label: rule.action, tint: rule.action.hasPrefix("ALLOW") ? Theme.success : rule.action.hasPrefix("LIMIT") ? Theme.warning : Theme.danger)
                                Text("from \(rule.from)")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button {
                                    ruleToDelete = rule
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete rule")
                            }
                            .padding(.vertical, 7)
                            if rule.id != firewall.rules.last?.id { Divider() }
                        }
                    }
                }
            } else if loading {
                ProgressView().controlSize(.small)
            }
        }
        .cardBackground(padding: 16)
    }

    private func isSSHRule(_ rule: FirewallRule) -> Bool {
        let target = rule.target.lowercased()
        return target.hasPrefix("openssh") || target.hasPrefix("\(server.port)/") || target.hasPrefix("\(server.port) ") || target == "\(server.port)"
    }

    // MARK: - Ports

    private var portsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconTile(systemImage: "point.3.connected.trianglepath.dotted")
                Text("Listening Ports").font(.headline)
                Spacer()
                Toggle("Include localhost-only", isOn: $showLocalOnly)
                    .toggleStyle(.checkbox)
                    .font(.callout)
            }

            if loading && ports.isEmpty {
                ProgressView().controlSize(.small)
            } else if visiblePorts.isEmpty {
                Text("Nothing listening.").foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    Text("Port").frame(width: 64, alignment: .leading)
                    Text("Proto").frame(width: 50, alignment: .leading)
                    Text("Bound to").frame(width: 170, alignment: .leading)
                    Text("Process").frame(maxWidth: .infinity, alignment: .leading)
                    Text("").frame(width: 150)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    ForEach(visiblePorts) { port in
                        portRow(port)
                        if port.id != visiblePorts.last?.id { Divider() }
                    }
                }
            }
        }
        .cardBackground(padding: 16)
    }

    private func portRow(_ port: ListeningPort) -> some View {
        let forward = forwards.forward(for: server.id, remotePort: port.port)
        return HStack(spacing: 12) {
            Text(verbatim: String(port.port))
                .font(.callout.monospacedDigit().weight(.semibold))
                .frame(width: 64, alignment: .leading)
            Text(port.proto.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .leading)
            HStack(spacing: 5) {
                Image(systemName: port.isLocalOnly ? "lock.fill" : "globe")
                    .font(.system(size: 10))
                    .foregroundStyle(port.isLocalOnly ? Color.secondary : Theme.warning)
                Text(port.address)
                    .font(.caption.monospaced())
                    .lineLimit(1)
            }
            .help(port.isLocalOnly ? "Only reachable from the server itself" : "Reachable from outside (subject to the firewall)")
            .frame(width: 170, alignment: .leading)
            Text(port.process ?? "—")
                .font(.callout)
                .foregroundStyle(port.process == nil ? .tertiary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if port.proto == "tcp" {
                    if let forward {
                        Button(String("localhost:\(forward.localPort)")) {
                            NSWorkspace.shared.open(URL(string: "http://localhost:\(forward.localPort)")!)
                        }
                        .help("Open in your Mac's browser")
                        Button {
                            forwards.stop(forward)
                        } label: {
                            Image(systemName: "stop.fill")
                        }
                        .help("Stop forwarding")
                    } else {
                        Button("Forward to Mac") {
                            do {
                                _ = try forwards.start(server: server, remotePort: port.port)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                        .help("Tunnel this port to your Mac over SSH")
                    }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 150, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Loading

    private func load() async {
        loading = true
        defer { loading = false }
        async let portsResult = captureResult { try await NetworkService.shared.listeningPorts(server) }
        async let firewallResult = captureResult { try await NetworkService.shared.firewall(server) }
        switch await portsResult {
        case .success(let list): ports = list; errorMessage = nil
        case .failure(let error): errorMessage = error.localizedDescription
        }
        switch await firewallResult {
        case .success(let status): firewall = status; firewallError = nil
        case .failure(let error): firewallError = error.localizedDescription
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await action()
                firewallError = nil
            } catch {
                firewallError = error.localizedDescription
            }
            await load()
        }
    }
}

private struct AddFirewallRuleSheet: View {
    let server: Server
    var onDone: () async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var action: NetworkService.RuleAction = .allow
    @State private var port = ""
    @State private var proto = "tcp"
    @State private var from = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Picker("Action", selection: $action) {
                    Text("Allow").tag(NetworkService.RuleAction.allow)
                    Text("Deny").tag(NetworkService.RuleAction.deny)
                    Text("Limit (rate-limit)").tag(NetworkService.RuleAction.limit)
                }
                TextField("Port", text: $port, prompt: Text("e.g. 8080, 3000:3010 or Nginx Full"))
                Picker("Protocol", selection: $proto) {
                    Text("TCP").tag("tcp")
                    Text("UDP").tag("udp")
                    Text("Both").tag("any")
                }
                .pickerStyle(.segmented)
                TextField("From", text: $from, prompt: Text("Anywhere (or an IP / CIDR)"))
                if let error {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Rule") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(port.trimmingCharacters(in: .whitespaces).isEmpty || saving)
            }
            .padding(14)
        }
        .frame(width: 440)
    }

    private func save() {
        saving = true
        let trimmed = port.trimmingCharacters(in: .whitespaces)
        // App profiles ("Nginx Full") don't take a protocol.
        let isProfile = trimmed.rangeOfCharacter(from: .letters) != nil
        Task {
            defer { saving = false }
            do {
                try await NetworkService.shared.addRule(server, action: action, port: trimmed,
                                                        proto: isProfile || proto == "any" ? nil : proto,
                                                        from: from.trimmingCharacters(in: .whitespaces))
                await onDone()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// `Result(catching:)` for async work, so several loads can run with `async let`
/// and each report its own error.
func captureResult<T>(_ operation: () async throws -> T) async -> Result<T, Error> {
    do { return .success(try await operation()) } catch { return .failure(error) }
}
