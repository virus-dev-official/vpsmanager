import SwiftUI

struct ServerSetupWizardView: View {
    var onComplete: (Server) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var setupService = ServerSetupService()

    enum Mode { case choose, quickAdd, physicalPC, freshHardening }
    @State private var mode: Mode = .choose

    // Quick add (already hardened) fields
    @State private var qaNickname = ""
    @State private var qaHost = ""
    @State private var qaPort = "22"
    @State private var qaUser = ""
    @State private var qaIdentity = "~/.ssh/id_ed25519"

    // Physical Ubuntu PC fields
    @State private var pcHost = ""
    @State private var pcPort = "22"
    @State private var pcUser = ""
    @State private var pcAccountPassword = ""

    // Fresh VPS fields
    @State private var fhHost = ""
    @State private var fhPort = "22"
    @State private var fhRootPassword = ""
    @State private var fhChangePassword = false
    @State private var fhNewPassword = ""
    @State private var fhConfirmPassword = ""
    @State private var fhKeyOnly = true
    @State private var fhCreateSudoUser = false
    @State private var fhUsername = ""

    private var fhPasswordProblem: String? {
        guard fhChangePassword else { return nil }
        if fhNewPassword.count < 8 { return "Use at least 8 characters." }
        if fhNewPassword != fhConfirmPassword { return "The passwords don't match." }
        return nil
    }

    private var fhUsernameValid: Bool {
        !fhCreateSudoUser || fhUsername.range(of: #"^[a-z_][a-z0-9_-]{0,31}$"#, options: .regularExpression) != nil
    }

    private var fhCanStart: Bool {
        !fhHost.trimmingCharacters(in: .whitespaces).isEmpty && !fhRootPassword.isEmpty
            && (Int(fhPort).map { (1...65535).contains($0) } ?? false)
            && fhPasswordProblem == nil && fhUsernameValid
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                switch mode {
                case .choose: chooseModeView
                case .quickAdd: existingServerView(
                    description: "Add a server that already has passwordless SSH configured.",
                    buttonTitle: "Add Server",
                    isHardened: true
                )
                case .physicalPC: physicalPCView
                case .freshHardening: freshHardeningView
                }
            }
            .padding(24)
        }
        .frame(width: 580, height: 600)
    }

    var header: some View {
        HStack {
            Text("Add Server").font(.title2.bold())
            Spacer()
            Button("Cancel") { dismiss() }
        }
        .padding(20)
    }

    var chooseModeView: some View {
        VStack(spacing: 16) {
            Text("How would you like to add this server?")
                .foregroundStyle(.secondary)

            Button {
                mode = .quickAdd
            } label: {
                optionRow(icon: "checkmark.seal", title: "Already set up",
                          subtitle: "Add a server that already has passwordless SSH configured.")
            }
            .buttonStyle(.plain)

            Button {
                mode = .physicalPC
            } label: {
                optionRow(icon: "desktopcomputer", title: "Physical Ubuntu PC (existing account)",
                          subtitle: "Use the account's password to install a generated SSH key for a user already on the PC.")
            }
            .buttonStyle(.plain)

            Button {
                mode = .freshHardening
            } label: {
                optionRow(icon: "wand.and.stars", title: "Fresh VPS (root + password)",
                          subtitle: "Log in as root once with the password, install my key for root, optionally set a new root password, and switch SSH to key-only.")
            }
            .buttonStyle(.plain)

            Spacer()
        }
    }

    func optionRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    func existingServerView(description: String, buttonTitle: String, isHardened: Bool) -> some View {
        Form {
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField("Nickname", text: $qaNickname, prompt: Text("e.g. web-prod"))
            TextField("Host / IP", text: $qaHost, prompt: Text("203.0.113.10"))
            TextField("Port", text: $qaPort)
            TextField("User", text: $qaUser, prompt: Text("deploy"))
            TextField("Identity File", text: $qaIdentity)
            Spacer()
            HStack {
                Button("Back") { mode = .choose }
                Spacer()
                Button(buttonTitle) {
                    let server = Server(nickname: qaNickname.isEmpty ? qaHost : qaNickname,
                                         host: qaHost, port: Int(qaPort) ?? 22, user: qaUser,
                                         identityFile: qaIdentity, isHardened: isHardened)
                    onComplete(server)
                }
                .buttonStyle(.borderedProminent)
                .disabled(qaHost.isEmpty || qaUser.isEmpty)
            }
        }
    }

    var physicalPCView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if setupService.isRunning {
                setupProgressView
            } else {
                Form {
                    Text("A dedicated SSH key will be generated on this Mac and installed for the existing user. The account password is used to SSH in and run sudo; no users or SSH settings are changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    TextField("PC IP address", text: $pcHost, prompt: Text("192.168.1.50"))
                    TextField("SSH Port", text: $pcPort)
                    TextField("Existing Username", text: $pcUser, prompt: Text("ubuntu"))
                    SecureField("Account Password", text: $pcAccountPassword)

                    if let error = setupService.error {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(.callout)
                    }

                    HStack {
                        Button("Back") { mode = .choose }
                        Spacer()
                        Button("Set Up Ubuntu PC") {
                            guard let port = Int(pcPort) else { return }
                            Task {
                                let input = ServerSetupService.PhysicalPCInput(
                                    host: pcHost.trimmingCharacters(in: .whitespacesAndNewlines),
                                    port: port,
                                    username: pcUser.trimmingCharacters(in: .whitespacesAndNewlines),
                                    accountPassword: pcAccountPassword
                                )
                                if let server = await setupService.runPhysicalPC(input) {
                                    onComplete(server)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            pcHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            pcUser.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                            pcAccountPassword.isEmpty ||
                            !(Int(pcPort).map { (1...65535).contains($0) } ?? false)
                        )
                    }
                }
            }
        }
    }

    var setupProgressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(setupService.steps.enumerated()), id: \.offset) { idx, step in
                HStack {
                    if idx < setupService.currentStepIndex {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.primary)
                    } else if idx == setupService.currentStepIndex {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "circle").foregroundStyle(.tertiary)
                    }
                    Text(step)
                }
            }
            ScrollView {
                Text(setupService.log)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 170)
            .background(.black.opacity(0.85))
            .foregroundStyle(Color(white: 0.85))
            .cornerRadius(8)
        }
    }

    var freshHardeningView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !setupService.isRunning && !setupService.finished && setupService.error == nil {
                Form {
                    Section {
                        TextField("Host / IP", text: $fhHost, prompt: Text("203.0.113.10"))
                        TextField("SSH Port", text: $fhPort)
                        SecureField("Root Password", text: $fhRootPassword)
                    } footer: {
                        Text("Used once to log in and install your SSH key for root. It isn't stored.")
                    }

                    Section {
                        Picker("Root password", selection: $fhChangePassword) {
                            Text("Keep current").tag(false)
                            Text("Set a new one").tag(true)
                        }
                        .pickerStyle(.segmented)
                        if fhChangePassword {
                            SecureField("New Root Password", text: $fhNewPassword)
                            SecureField("Confirm New Password", text: $fhConfirmPassword)
                            if let problem = fhPasswordProblem, !fhNewPassword.isEmpty {
                                Text(problem).font(.caption).foregroundStyle(Theme.danger)
                            }
                        }
                    }

                    Section {
                        Toggle("Turn off password logins (key only)", isOn: $fhKeyOnly)
                        Toggle("Also create a sudo user", isOn: $fhCreateSudoUser)
                        if fhCreateSudoUser {
                            TextField("Username", text: $fhUsername, prompt: Text("deploy"))
                            if !fhUsernameValid && !fhUsername.isEmpty {
                                Text("Lowercase letters, digits, - and _ only.").font(.caption).foregroundStyle(Theme.danger)
                            }
                        }
                    } footer: {
                        Text(fhKeyOnly
                             ? "Recommended. Root keeps logging in with your key; nobody can log in with a password, which stops brute-force attacks."
                             : "Root can log in with your key or with the password. Easier to get into from elsewhere, but exposed to password guessing.")
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Button("Back") { mode = .choose }
                    Spacer()
                    Button("Start Setup") { startFreshSetup() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!fhCanStart)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(setupService.steps.enumerated()), id: \.offset) { idx, step in
                        HStack {
                            if idx < setupService.currentStepIndex || setupService.finished {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                            } else if idx == setupService.currentStepIndex && setupService.error != nil {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                            } else if idx == setupService.currentStepIndex {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "circle").foregroundStyle(.tertiary)
                            }
                            Text(step)
                        }
                    }
                }
                ScrollView {
                    Text(setupService.log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: .infinity)
                .padding(8)
                .background(.black.opacity(0.85))
                .foregroundStyle(Color(white: 0.85))
                .cornerRadius(8)

                if let error = setupService.error {
                    Text(error).foregroundStyle(Theme.danger).font(.callout).textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button("Edit & Retry") { setupService.error = nil }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
    }

    private func startFreshSetup() {
        let input = ServerSetupService.Input(
            host: fhHost.trimmingCharacters(in: .whitespacesAndNewlines),
            port: Int(fhPort) ?? 22,
            rootPassword: fhRootPassword,
            newRootPassword: fhChangePassword ? fhNewPassword : nil,
            sudoUsername: fhCreateSudoUser ? fhUsername : nil,
            disablePasswordLogin: fhKeyOnly
        )
        Task {
            let servers = await setupService.run(input)
            // Root last, so it's the one selected afterwards.
            for server in servers.reversed() { onComplete(server) }
        }
    }
}
