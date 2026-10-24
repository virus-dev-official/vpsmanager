import SwiftUI
import SwiftTerm
import AppKit

/// Wraps SwiftTerm's LocalProcessTerminalView to run `ssh <server>` directly, giving
/// a fully working native terminal (same PTY approach real terminal apps use —
/// supports vim, htop, colors, resizing, everything).
final class SSHTerminalView: LocalProcessTerminalView {
    private(set) var serverID: UUID?

    func connect(server: Server) {
        serverID = server.id
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        nativeBackgroundColor = NSColor(hex: 0x15110F)
        nativeForegroundColor = NSColor(hex: 0xEFE7E3)
        caretColor = NSColor(hex: 0xFF7A3D)
        // startProcess expects the executable followed by its own argv (argv[0] included by SwiftTerm).
        startProcess(executable: "/usr/bin/env", args: ["ssh"] + server.sshArgs, environment: nil, execName: nil)
    }
}

/// Owns every terminal session in the app, independent of any view. Sessions live
/// here (not in SwiftUI state), so switching tabs, switching servers or even
/// closing and reopening a window leaves running shells — and their scrollback —
/// exactly where they were.
@MainActor
final class TerminalSessionManager: NSObject, ObservableObject {
    static let shared = TerminalSessionManager()

    final class Session: Identifiable {
        let id = UUID()
        let serverID: UUID
        let number: Int
        let view: SSHTerminalView
        var title: String
        var exited = false

        init(serverID: UUID, number: Int, view: SSHTerminalView, title: String) {
            self.serverID = serverID
            self.number = number
            self.view = view
            self.title = title
        }
    }

    @Published private(set) var sessions: [Session] = []
    @Published var activeSessionID: [UUID: UUID] = [:]   // server id → session id

    func sessions(for serverID: UUID) -> [Session] {
        sessions.filter { $0.serverID == serverID }
    }

    func activeSession(for serverID: UUID) -> Session? {
        let list = sessions(for: serverID)
        return list.first { $0.id == activeSessionID[serverID] } ?? list.last
    }

    @discardableResult
    func newSession(on server: Server) -> Session {
        let number = (sessions(for: server.id).map(\.number).max() ?? 0) + 1
        let view = SSHTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.processDelegate = self
        let session = Session(serverID: server.id, number: number, view: view, title: "Shell \(number)")
        sessions.append(session)
        activeSessionID[server.id] = session.id
        view.connect(server: server)
        return session
    }

    /// Makes sure the server has at least one session (started lazily, the first
    /// time its Terminal tab is actually shown).
    func ensureSession(on server: Server) {
        if sessions(for: server.id).isEmpty { newSession(on: server) }
    }

    func close(_ session: Session) {
        if !session.exited { session.view.terminate() }
        session.view.removeFromSuperview()
        sessions.removeAll { $0.id == session.id }
        if activeSessionID[session.serverID] == session.id {
            activeSessionID[session.serverID] = sessions(for: session.serverID).last?.id
        }
    }

    /// Replaces an ended (or stuck) session with a fresh connection in the same slot.
    func reconnect(_ session: Session, server: Server) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        if !session.exited { session.view.terminate() }
        session.view.removeFromSuperview()
        let view = SSHTerminalView(frame: session.view.frame)
        view.processDelegate = self
        let replacement = Session(serverID: session.serverID, number: session.number, view: view, title: "Shell \(session.number)")
        sessions[index] = replacement
        activeSessionID[server.id] = replacement.id
        view.connect(server: server)
    }

    func closeAll(for serverID: UUID) {
        for session in sessions(for: serverID) { close(session) }
    }

    /// Sends a `cd` as if the user had typed it, so the running remote shell
    /// actually changes directory (as opposed to just cosmetically showing a path).
    /// Starts a session first if the server doesn't have one yet.
    func cd(to path: String, on server: Server) {
        ensureSession(on: server)
        guard let session = activeSession(for: server.id), !session.exited else { return }
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        session.view.send(txt: "cd '\(escaped)'\n")
    }

    fileprivate func session(for view: TerminalView) -> Session? {
        sessions.first { $0.view === view }
    }
}

extension TerminalSessionManager: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        Task { @MainActor in
            guard let session = self.session(for: source), !title.isEmpty else { return }
            session.title = title
            self.objectWillChange.send()
        }
    }

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            guard let session = self.session(for: source) else { return }
            session.exited = true
            self.objectWillChange.send()
        }
    }
}

/// Hosts whichever session is active inside a plain container view, re-parenting
/// the long-lived terminal view instead of recreating it.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSessionManager.Session
    let isActive: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(hex: 0x15110F).cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let view = session.view
        if view.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            view.removeFromSuperview()
            // Constraints, not a frame copied from `container.bounds`: SwiftUI
            // calls this before the container has been sized, and a frame taken
            // from a zero-size container stays zero-size (an invisible terminal
            // whose shell is happily running behind it).
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -6),
                view.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
                view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            ])
            container.needsLayout = true
        }
        if isActive && !session.exited {
            DispatchQueue.main.async {
                if view.window != nil, view.window?.firstResponder !== view {
                    view.window?.makeFirstResponder(view)
                }
            }
        }
    }
}

struct TerminalTabView: View {
    let server: Server
    var isActive: Bool = true
    @ObservedObject private var manager = TerminalSessionManager.shared

    var body: some View {
        let sessions = manager.sessions(for: server.id)
        let active = manager.activeSession(for: server.id)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(sessions) { session in
                            TerminalTabChip(
                                title: session.title,
                                exited: session.exited,
                                isSelected: session.id == active?.id,
                                onSelect: { manager.activeSessionID[server.id] = session.id },
                                onClose: { manager.close(session) }
                            )
                        }
                    }
                }
                .scrollIndicators(.never)

                Button {
                    manager.newSession(on: server)
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .help("New terminal tab")

                Spacer(minLength: 8)

                Text(server.sshTarget + (server.port == 22 ? "" : ":\(server.port)"))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let active {
                    Button {
                        manager.reconnect(active, server: server)
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surface)

            Rectangle().fill(Theme.stroke).frame(height: 1)

            ZStack {
                Color(nsColor: NSColor(hex: 0x15110F))
                if let active {
                    TerminalHost(session: active, isActive: isActive)
                        .id(active.id)
                    if active.exited {
                        VStack(spacing: 12) {
                            Image(systemName: "bolt.horizontal.circle")
                                .font(.system(size: 28))
                                .foregroundStyle(.white.opacity(0.6))
                            Text("Session ended")
                                .font(.headline)
                                .foregroundStyle(.white)
                            Button {
                                manager.reconnect(active, server: server)
                            } label: {
                                Label("Reconnect", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(24)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                } else {
                    Button {
                        manager.newSession(on: server)
                    } label: {
                        Label("Open a Shell", systemImage: "terminal")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
        .onAppear { if isActive { manager.ensureSession(on: server) } }
        .onChange(of: isActive) { _, nowActive in
            if nowActive { manager.ensureSession(on: server) }
        }
    }
}

private struct TerminalTabChip: View {
    let title: String
    let exited: Bool
    let isSelected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(exited ? Theme.danger : Theme.success)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering || isSelected ? 1 : 0)
            .help("Close tab")
        }
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.accent.opacity(0.14) : (hovering ? Theme.surfaceAlt : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }
}
