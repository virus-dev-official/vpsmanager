import SwiftUI

/// One concrete `Host` block from ~/.ssh/config.
struct SSHConfigHost: Identifiable, Hashable {
    var id: String { alias }
    let alias: String
    var hostName: String
    var user: String
    var port: Int
    var identityFile: String
}

/// Minimal ~/.ssh/config reader: concrete `Host` aliases (wildcard patterns are
/// skipped) with HostName / User / Port / IdentityFile, values from `Host *`
/// blocks applied as defaults, and `Include` files followed.
enum SSHConfigParser {
    static func load(path: String = "~/.ssh/config") -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var defaults: [String: String] = [:]
        var visited = Set<String>()
        parse(file: (path as NSString).expandingTildeInPath, hosts: &hosts, defaults: &defaults, visited: &visited)
        return hosts.map { host in
            var h = host
            if h.user.isEmpty { h.user = defaults["user"] ?? NSUserName() }
            if h.identityFile.isEmpty { h.identityFile = defaults["identityfile"] ?? "" }
            if h.port == 0 { h.port = Int(defaults["port"] ?? "") ?? 22 }
            return h
        }
    }

    private static func parse(file: String, hosts: inout [SSHConfigHost], defaults: inout [String: String], visited: inout Set<String>) {
        guard visited.insert(file).inserted, let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
        var current: [String] = []          // aliases of the block being read
        var isWildcardBlock = false
        var values: [String: String] = [:]

        func flush() {
            if isWildcardBlock {
                for (k, v) in values where defaults[k] == nil { defaults[k] = v }
            } else {
                for alias in current {
                    hosts.append(SSHConfigHost(
                        alias: alias,
                        hostName: values["hostname"] ?? alias,
                        user: values["user"] ?? "",
                        port: Int(values["port"] ?? "") ?? 0,
                        identityFile: values["identityfile"] ?? ""
                    ))
                }
            }
            current = []
            values = [:]
            isWildcardBlock = false
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \t=\""))

            switch key {
            case "host":
                flush()
                let patterns = value.split(separator: " ").map(String.init)
                if patterns.contains("*") {
                    isWildcardBlock = true
                } else {
                    current = patterns.filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
                }
            case "match":
                flush()
                current = []   // Match blocks are conditional; ignore their contents
            case "include":
                for pattern in value.split(separator: " ") {
                    let expanded = (String(pattern) as NSString).expandingTildeInPath
                    let full = expanded.hasPrefix("/") ? expanded : ("~/.ssh/" as NSString).expandingTildeInPath + "/" + expanded
                    for match in glob(full) {
                        parse(file: match, hosts: &hosts, defaults: &defaults, visited: &visited)
                    }
                }
            default:
                // First value wins in ssh_config.
                if values[key] == nil { values[key] = value }
            }
        }
        flush()
    }

    private static func glob(_ pattern: String) -> [String] {
        var g = glob_t()
        defer { globfree(&g) }
        guard Darwin.glob(pattern, 0, nil, &g) == 0 else { return [] }
        return (0..<Int(g.gl_matchc)).compactMap { g.gl_pathv[$0].flatMap { String(cString: $0) } }
    }
}

struct SSHConfigImportView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [SSHConfigHost] = []
    @State private var selected: Set<String> = []

    private func alreadyAdded(_ host: SSHConfigHost) -> Bool {
        store.servers.contains { $0.host.lowercased() == host.hostName.lowercased() && $0.user == host.user && $0.port == host.port }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(systemImage: "square.and.arrow.down", size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from SSH Config").font(.title3.weight(.semibold))
                    Text("Hosts defined in ~/.ssh/config. Key-based login is assumed, as in your config.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Rectangle().fill(Theme.stroke).frame(height: 1)

            if hosts.isEmpty {
                ContentUnavailableView("No Hosts Found", systemImage: "doc.text.magnifyingglass",
                                       description: Text("~/.ssh/config has no concrete Host entries."))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(hosts) { host in
                        let added = alreadyAdded(host)
                        Toggle(isOn: Binding(
                            get: { selected.contains(host.id) },
                            set: { on in if on { selected.insert(host.id) } else { selected.remove(host.id) } }
                        )) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(host.alias).font(.callout.weight(.semibold))
                                    Text("\(host.user)@\(host.hostName)\(host.port == 22 ? "" : ":\(host.port)")")
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if added {
                                    Text("Already added").font(.caption).foregroundStyle(.secondary)
                                } else if !host.identityFile.isEmpty {
                                    Text((host.identityFile as NSString).lastPathComponent)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .disabled(added)
                    }
                }
                .listStyle(.inset)
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack {
                Button("Select All") {
                    selected = Set(hosts.filter { !alreadyAdded($0) }.map(\.id))
                }
                .disabled(hosts.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) Server\(selected.count == 1 ? "" : "s")") { importSelected() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 560, height: 480)
        .onAppear { hosts = SSHConfigParser.load() }
    }

    private func importSelected() {
        let defaultKey = FileManager.default.fileExists(atPath: ("~/.ssh/id_ed25519" as NSString).expandingTildeInPath) ? "~/.ssh/id_ed25519" : ""
        for host in hosts where selected.contains(host.id) && !alreadyAdded(host) {
            store.servers.append(Server(
                nickname: host.alias,
                host: host.hostName,
                port: host.port,
                user: host.user,
                identityFile: host.identityFile.isEmpty ? defaultKey : host.identityFile,
                isHardened: false
            ))
        }
        Task { await FleetStatus.shared.refresh(store: store) }
        dismiss()
    }
}
