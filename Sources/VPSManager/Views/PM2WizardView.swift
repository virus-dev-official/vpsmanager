import SwiftUI

struct PM2WizardView: View {
    let server: Server
    var onComplete: (PM2AppConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: AppStore

    @State private var step = 0
    @State private var type: PM2AppType = .node
    @State private var name = ""
    @State private var remoteCwd = ""
    @State private var remoteEntryFile = ""
    @State private var args = ""
    @State private var envRows: [(String, String)] = [("", "")]
    @State private var execMode: PM2ExecMode = .fork
    @State private var instances = 1
    @State private var maxMemory = ""
    @State private var watch = false

    // Python-specific
    @State private var discoveredVenvs: [String] = []
    @State private var discoveredRequirements: [String] = []
    @State private var venvChoice: VenvChoice = .createNew
    @State private var selectedExistingVenv = ""
    @State private var newVenvPath = ""
    @State private var selectedRequirements = ""
    @State private var loadingDiscovery = false

    @State private var deploying = false
    @State private var deployLog = ""
    @State private var deployError: String?
    @State private var deployedConfig: PM2AppConfig?

    enum VenvChoice { case createNew, useExisting, none }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("New PM2 App").font(.title2.bold())
                Spacer()
                Button("Cancel") { dismiss() }
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    typePicker
                    basicsSection
                    if type == .python { pythonSection }
                    runtimeSection
                    envSection

                    if let deployError {
                        Text(deployError).foregroundStyle(.red)
                    }
                    if !deployLog.isEmpty {
                        ScrollView {
                            Text(deployLog).font(.system(.caption, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 120)
                        .background(.black.opacity(0.85))
                        .foregroundStyle(Color(white: 0.85))
                        .cornerRadius(8)
                    }
                }
                .padding(24)
            }

            Divider()
            HStack {
                Spacer()
                if deployedConfig != nil {
                    Button("Done") { onComplete(deployedConfig!) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(deploying ? "Deploying…" : "Deploy & Start") {
                        Task { await deploy() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(deploying || name.isEmpty || remoteCwd.isEmpty || remoteEntryFile.isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 680, height: 720)
        .task { await discoverIfNeeded() }
    }

    var typePicker: some View {
        Picker("App Type", selection: $type) {
            ForEach(PM2AppType.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .onChange(of: type) { _, _ in Task { await discoverIfNeeded() } }
    }

    var basicsSection: some View {
        GroupBox("Basics") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("App name", text: $name, prompt: Text("my-app-backend"))
                TextField("Working directory (cwd)", text: $remoteCwd, prompt: Text("/home/\(server.user)/my-app"))
                    .onChange(of: remoteCwd) { _, _ in Task { await discoverIfNeeded() } }
                TextField(type == .node ? "Entry file (e.g. dist/index.js)" : "Entry file (e.g. app.py)", text: $remoteEntryFile)
                TextField("Extra args (optional)", text: $args)
            }
            .padding(8)
        }
    }

    var pythonSection: some View {
        GroupBox("Python Environment") {
            VStack(alignment: .leading, spacing: 10) {
                if loadingDiscovery {
                    ProgressView("Scanning for existing venvs…").controlSize(.small)
                }
                Picker("Virtual environment", selection: $venvChoice) {
                    Text("Create new venv").tag(VenvChoice.createNew)
                    if !discoveredVenvs.isEmpty {
                        Text("Use existing venv").tag(VenvChoice.useExisting)
                    }
                    Text("No venv (use system python3)").tag(VenvChoice.none)
                }
                .pickerStyle(.radioGroup)

                if venvChoice == .createNew {
                    TextField("New venv path", text: $newVenvPath, prompt: Text("\(remoteCwd)/venv"))
                } else if venvChoice == .useExisting {
                    Picker("Existing venv", selection: $selectedExistingVenv) {
                        ForEach(discoveredVenvs, id: \.self) { Text($0).tag($0) }
                    }
                }

                if !discoveredRequirements.isEmpty {
                    Picker("requirements.txt", selection: $selectedRequirements) {
                        Text("None").tag("")
                        ForEach(discoveredRequirements, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            .padding(8)
        }
    }

    var runtimeSection: some View {
        GroupBox("Runtime") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Exec mode", selection: $execMode) {
                    ForEach(PM2ExecMode.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                if execMode == .cluster {
                    Stepper("Instances: \(instances)", value: $instances, in: 1...16)
                }
                TextField("Max memory restart (e.g. 300M)", text: $maxMemory)
                Toggle("Watch for file changes & auto-restart", isOn: $watch)
            }
            .padding(8)
        }
    }

    var envSection: some View {
        GroupBox("Environment Variables") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(envRows.indices, id: \.self) { i in
                    HStack {
                        TextField("KEY", text: Binding(
                            get: { envRows[i].0 }, set: { envRows[i].0 = $0 }
                        ))
                        TextField("value", text: Binding(
                            get: { envRows[i].1 }, set: { envRows[i].1 = $0 }
                        ))
                        Button {
                            envRows.remove(at: i)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                    }
                }
                Button {
                    envRows.append(("", ""))
                } label: { Label("Add Variable", systemImage: "plus") }
                .buttonStyle(.plain)
            }
            .padding(8)
        }
    }

    func discoverIfNeeded() async {
        guard type == .python, !remoteCwd.isEmpty else { return }
        loadingDiscovery = true
        discoveredVenvs = (try? await PM2Service.shared.discoverVenvs(server, underPath: remoteCwd)) ?? []
        discoveredRequirements = (try? await PM2Service.shared.discoverRequirementsFiles(server, underPath: remoteCwd)) ?? []
        if venvChoice == .useExisting, selectedExistingVenv.isEmpty {
            selectedExistingVenv = discoveredVenvs.first ?? ""
        }
        if selectedRequirements.isEmpty {
            selectedRequirements = discoveredRequirements.first ?? ""
        }
        loadingDiscovery = false
    }

    func deploy() async {
        deploying = true
        deployError = nil
        defer { deploying = false }

        var env: [String: String] = [:]
        for (k, v) in envRows where !k.isEmpty { env[k] = v }

        var venvPath = ""
        if type == .python {
            switch venvChoice {
            case .createNew: venvPath = newVenvPath.isEmpty ? "\(remoteCwd)/venv" : newVenvPath
            case .useExisting: venvPath = selectedExistingVenv
            case .none: venvPath = ""
            }
        }

        let config = PM2AppConfig(
            serverID: server.id,
            projectID: nil,
            name: name,
            type: type,
            remoteEntryFile: remoteEntryFile,
            remoteCwd: remoteCwd,
            venvPath: venvPath,
            args: args,
            env: env,
            execMode: execMode,
            instances: instances,
            maxMemoryRestart: maxMemory,
            watch: watch
        )

        do {
            try await PM2Service.shared.deploy(server, config: config, requirementsPath: selectedRequirements.isEmpty ? nil : selectedRequirements) { line in
                deployLog += line
            }
            deployedConfig = config
        } catch {
            deployError = error.localizedDescription
        }
    }
}