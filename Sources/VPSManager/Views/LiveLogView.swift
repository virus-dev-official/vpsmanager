import SwiftUI
import AppKit

/// Streams a long-running remote command (`pm2 logs`, `journalctl -f`,
/// `docker logs -f` …) line by line, with follow/pause, a live search filter,
/// copy and clear. One implementation for every log screen in the app.
@MainActor
final class LogStream: ObservableObject {
    struct Line: Identifiable {
        let id: Int
        let text: String
    }

    @Published private(set) var lines: [Line] = []
    @Published private(set) var isRunning = false
    @Published private(set) var endedMessage: String?

    private var pty: PTYProcess?
    private var partial = ""
    private var nextID = 0
    private var seenMarker = false
    private let maxLines = 5000

    func start(server: Server, command: String) {
        stop()
        endedMessage = nil
        partial = ""
        seenMarker = false
        // Same login-shell wrapping as ShellService.ssh (PATH from .bashrc for
        // pm2/nvm), with the same marker so profile banners don't land in the log.
        let marked = "printf '%s\\n' '\(ShellService.outputMarker)'\n" + command
        let escaped = marked.replacingOccurrences(of: "'", with: "'\\''")
        let p = PTYProcess()
        p.onOutput = { [weak self] chunk in self?.ingest(chunk) }
        p.onExit = { [weak self] code in
            guard let self, self.pty === p else { return }
            self.isRunning = false
            self.endedMessage = code == 0 ? "Stream ended." : "Stream ended (exit code \(code))."
        }
        p.start(executable: "ssh", arguments: ["-t"] + server.sshArgs + ["bash -ilc '\(escaped)'"],
                environment: ProcessInfo.processInfo.environment)
        pty = p
        isRunning = true
    }

    func stop() {
        let old = pty
        pty = nil
        old?.terminate()
        isRunning = false
    }

    func clear() {
        lines.removeAll()
    }

    private func ingest(_ chunk: String) {
        partial += chunk.strippingANSICodes()
        var parts = partial.components(separatedBy: "\n")
        partial = parts.removeLast()
        var fresh: [Line] = []
        for raw in parts {
            let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !seenMarker {
                if text.contains(ShellService.outputMarker) { seenMarker = true }
                continue
            }
            fresh.append(Line(id: nextID, text: text))
            nextID += 1
        }
        guard !fresh.isEmpty else { return }
        lines.append(contentsOf: fresh)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }
}

struct LiveLogView<Accessory: View>: View {
    let server: Server
    let title: String
    let command: String
    @ViewBuilder var accessory: Accessory
    @Environment(\.dismiss) private var dismiss

    @StateObject private var stream = LogStream()
    @State private var query = ""
    @State private var follow = true
    @State private var wrap = true

    private var visible: [LogStream.Line] {
        guard !query.isEmpty else { return stream.lines }
        return stream.lines.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let shown = visible
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(systemImage: "doc.plaintext", size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(stream.isRunning ? Theme.success : Color.secondary).frame(width: 6, height: 6)
                        Text(stream.isRunning ? "Live" : (stream.endedMessage ?? "Paused"))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                accessory
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Filter lines", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Text("\(shown.count) match\(shown.count == 1 ? "" : "es")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button { query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))

                Toggle(isOn: $follow) { Label("Follow", systemImage: "arrow.down.to.line") }
                    .toggleStyle(.button)
                    .help("Keep scrolled to the newest line")
                Toggle(isOn: $wrap) { Label("Wrap", systemImage: "text.word.spacing") }
                    .toggleStyle(.button)
                    .labelStyle(.iconOnly)
                    .help("Wrap long lines")

                Button {
                    stream.isRunning ? stream.stop() : stream.start(server: server, command: command)
                } label: {
                    Image(systemName: stream.isRunning ? "pause.fill" : "play.fill")
                }
                .help(stream.isRunning ? "Pause stream" : "Resume stream")
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shown.map(\.text).joined(separator: "\n"), forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy visible lines")
                Button { stream.clear() } label: { Image(systemName: "trash") }
                    .help("Clear")
            }
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Rectangle().fill(Theme.stroke).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView(wrap ? .vertical : [.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { line in
                            highlighted(line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(for: line.text))
                                .fixedSize(horizontal: !wrap, vertical: true)
                                .frame(maxWidth: wrap ? .infinity : nil, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: NSColor(hex: 0x15110F)))
                .overlay {
                    if shown.isEmpty {
                        Text(query.isEmpty ? (stream.isRunning ? "Waiting for output…" : "No output.") : "No lines match “\(query)”.")
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .onChange(of: stream.lines.last?.id) { _, _ in
                    if follow, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
                .onChange(of: follow) { _, on in
                    if on, let last = shown.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Theme.surface)
        .onAppear { stream.start(server: server, command: command) }
        .onDisappear { stream.stop() }
        .onChange(of: command) { _, newCommand in
            stream.clear()
            stream.start(server: server, command: newCommand)
        }
    }

    private func highlighted(_ text: String) -> Text {
        guard !query.isEmpty, let range = text.range(of: query, options: .caseInsensitive) else { return Text(text) }
        var attributed = AttributedString(text)
        if let lower = AttributedString.Index(range.lowerBound, within: attributed),
           let upper = AttributedString.Index(range.upperBound, within: attributed) {
            attributed[lower..<upper].backgroundColor = Color.yellow.opacity(0.35)
            attributed[lower..<upper].foregroundColor = .white
        }
        return Text(attributed)
    }

    private func color(for line: String) -> Color {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("fatal") || lower.contains("exception") || lower.contains("failed") {
            return Color(nsColor: NSColor(hex: 0xFF7B72))
        }
        if lower.contains("warn") { return Color(nsColor: NSColor(hex: 0xE3B341)) }
        return Color(nsColor: NSColor(hex: 0xD8CEC9))
    }
}

extension LiveLogView where Accessory == EmptyView {
    init(server: Server, title: String, command: String) {
        self.init(server: server, title: title, command: command) { EmptyView() }
    }
}

// MARK: - Concrete log screens

struct PM2LogsView: View {
    let server: Server
    let processName: String
    @State private var kind: PM2Service.LogKind = .out

    var body: some View {
        let flag = kind == .out ? "--out" : "--err"
        LiveLogView(server: server, title: "pm2 logs \(processName)",
                    command: "pm2 logs \(shellQuoted(processName)) \(flag) --lines 200") {
            Picker("", selection: $kind) {
                Text("Output").tag(PM2Service.LogKind.out)
                Text("Errors").tag(PM2Service.LogKind.err)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
        }
    }
}

struct SystemdJournalView: View {
    let server: Server
    let unitName: String

    var body: some View {
        // System units' journals need root or the adm/systemd-journal group; use
        // passwordless sudo when available, otherwise whatever the user can read.
        let unit = shellQuoted(unitName)
        LiveLogView(server: server, title: "journalctl -u \(unitName)",
                    command: "if sudo -n true 2>/dev/null; then exec sudo -n journalctl -u \(unit) -n 300 -f --no-pager; else exec journalctl -u \(unit) -n 300 -f --no-pager; fi")
    }
}

/// Single-quotes a value for a remote shell command line.
func shellQuoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
