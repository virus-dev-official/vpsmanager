import Foundation
import AppKit
import ImageIO
import Darwin

// MARK: - Preferences

enum BrowserQuality: String, CaseIterable, Identifiable {
    case dataSaver, balanced, sharp
    var id: String { rawValue }
    static let storageKey = "browserQuality"

    var title: String {
        switch self {
        case .dataSaver: return "Data Saver"
        case .balanced: return "Balanced"
        case .sharp: return "Sharp (Retina)"
        }
    }

    var detail: String {
        switch self {
        case .dataSaver: return "Lowest bandwidth. Good on slow or metered connections."
        case .balanced: return "Standard resolution with good image quality."
        case .sharp: return "Full Retina resolution. Uses roughly 3× the bandwidth."
        }
    }

    var jpegQuality: Int {
        switch self {
        case .dataSaver: return 50
        case .balanced: return 78
        case .sharp: return 82
        }
    }

    func pixelScale(backingScale: CGFloat) -> CGFloat {
        self == .sharp ? max(1, backingScale) : 1
    }

    static var current: BrowserQuality {
        BrowserQuality(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .sharp
    }
}

enum BrowserSearchEngine: String, CaseIterable, Identifiable {
    case duckDuckGo, google, bing, brave
    var id: String { rawValue }
    static let storageKey = "browserSearchEngine"

    var title: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .google: return "Google"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        }
    }

    func searchURL(for query: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        let q = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q=\(q)"
        case .google: return "https://www.google.com/search?q=\(q)"
        case .bing: return "https://www.bing.com/search?q=\(q)"
        case .brave: return "https://search.brave.com/search?q=\(q)"
        }
    }

    var homePage: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .google: return "https://www.google.com/"
        case .bing: return "https://www.bing.com/"
        case .brave: return "https://search.brave.com/"
        }
    }

    static var current: BrowserSearchEngine {
        BrowserSearchEngine(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .duckDuckGo
    }
}

enum BrowserPreferences {
    static let keepRunningKey = "browserKeepRunningOnVPS"

    /// Whether disconnecting leaves Chromium running on the VPS (so tabs, logins
    /// and cookies are exactly where you left them next time). On by default.
    static var keepRunningOnVPS: Bool {
        UserDefaults.standard.object(forKey: keepRunningKey) as? Bool ?? true
    }
}

// MARK: - Value types

struct BrowserFrame: @unchecked Sendable {
    let image: CGImage
    /// The page viewport the frame represents, in CSS pixels. Mouse coordinates
    /// are mapped into this space before being sent to the page.
    let cssSize: CGSize
}

struct BrowserTab: Identifiable, Equatable {
    let id: String
    var title: String
    var url: String

    var displayTitle: String {
        if !title.isEmpty && title != url { return title }
        if url == "about:blank" || url.isEmpty { return "New Tab" }
        return URL(string: url)?.host ?? url
    }
}

struct BrowserDialog: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let kind: String   // alert | confirm | prompt | beforeunload
    let message: String
    let defaultPrompt: String
    let origin: String
}

struct ListeningService: Identifiable, Hashable {
    var id: Int { port }
    let port: Int
    let process: String?
    let isLoopbackOnly: Bool
}

// MARK: - Session

/// One remote Chromium per server, driven over the Chrome DevTools Protocol.
///
/// How it fits together:
///   1. Over the normal SSH connection, a small script finds Chromium/Chrome on the
///      VPS and launches it headless with `--remote-debugging-port=0` (the OS picks
///      a free port, which Chrome writes to `DevToolsActivePort`). It's bound to the
///      VPS's 127.0.0.1 only — never exposed to the internet.
///   2. A dedicated `ssh -N -L` tunnel maps a free port on this Mac to that port.
///   3. One WebSocket to the browser endpoint drives every tab: screencast frames
///      stream in as JPEGs, and mouse / keyboard / scroll input streams back out.
///
/// The browser keeps running on the VPS between connections (unless the user
/// turns that off), so tabs, logins and cookies persist like a real browser.
@MainActor
final class RemoteBrowserSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case notInstalled
        case installing
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var activeTabID: String?
    @Published private(set) var currentURL = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var isLoading = false
    @Published private(set) var browserVersion = ""
    /// True when Chromium had to run with --no-sandbox (running as root, or the
    /// server blocks the user-namespace sandbox). Surfaced in the status bar.
    @Published private(set) var sandboxDisabled = false
    @Published private(set) var viewportCSS: CGSize = .zero
    @Published private(set) var installLog = ""
    @Published private(set) var zoom: Double = 1
    @Published private(set) var services: [ListeningService] = []
    @Published private(set) var loadingServices = false
    /// A ready-to-paste sudoers fix when the last failure was a sudo password prompt.
    @Published private(set) var failureFix: String?
    @Published var dialog: BrowserDialog?
    @Published var notice: String?

    var server: Server

    /// Pushes decoded frames straight to the on-screen canvas, bypassing SwiftUI
    /// diffing (frames can arrive at 30–60 fps).
    var frameSink: ((BrowserFrame) -> Void)?
    weak var frameSinkOwner: AnyObject?
    private(set) var lastFrame: BrowserFrame?

    private var connection: CDPConnection?
    private var tunnel: Process?
    private var localPort: Int?
    private var remotePort: Int?
    private var remoteHome = ""
    private var remoteBase = ""
    private var userAgent: String?
    private var userAgentMetadata: [String: Any]?

    private var sessions: [String: String] = [:]          // targetId -> CDP sessionId
    private var activeSessionID: String?
    private var historyEntries: [(id: Int, url: String, title: String)] = []
    private var historyIndex = 0

    private var viewSize = CGSize(width: 1280, height: 800)
    private var backingScale: CGFloat = 2
    private var isVisible = false
    private var isScreencasting = false
    private var viewportTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    /// Bumped on every connect/disconnect so an in-flight `connect()` can notice it
    /// was superseded (user hit Disconnect mid-launch) and bail out cleanly.
    private var generation = 0
    private var lastModifiedClick = Date.distantPast

    static let zoomLevels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    init(server: Server) {
        self.server = server
    }

    var isConnected: Bool { phase == .ready }

    // MARK: Connect / disconnect

    func connect() async {
        switch phase {
        case .working, .installing, .ready: return
        default: break
        }
        generation += 1
        let gen = generation
        teardownLocal()
        installLog = ""
        failureFix = nil

        do {
            phase = .working("Starting Chromium on \(server.host)…")
            let launch = try await ShellService.shared.ssh(server, command: Self.launchScript, timeout: 75)
            guard gen == generation else { return }
            let values = Self.parseMarkers(launch.stdout)

            if values["VPSM_ERROR"] == "not_installed" {
                phase = .notInstalled
                return
            }
            if values["VPSM_ERROR"] == "launch_failed" {
                let log = Self.logSection(launch.stdout)
                throw SessionError.message("Chromium couldn't start on the VPS.\(log.isEmpty ? "" : "\n\n\(log)")")
            }
            guard let portString = values["VPSM_PORT"], let port = Int(portString) else {
                let detail = [launch.stderr, launch.stdout].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? "exit code \(launch.exitCode)"
                throw SessionError.message("Couldn't start the browser on the VPS: \(detail)")
            }
            remotePort = port
            remoteHome = values["VPSM_HOME"] ?? ""
            remoteBase = values["VPSM_BASE"] ?? ""
            sandboxDisabled = values["VPSM_SANDBOX"] == "off"

            phase = .working("Opening a secure SSH tunnel…")
            let version = try await openTunnel(remotePort: port, generation: gen)
            guard gen == generation else { return }

            phase = .working("Connecting to the browser…")
            guard let wsPath = (version["webSocketDebuggerUrl"] as? String).flatMap({ URL(string: $0)?.path }),
                  let localPort, let wsURL = URL(string: "ws://127.0.0.1:\(localPort)\(wsPath)") else {
                throw SessionError.message("The browser on the VPS didn't report a DevTools endpoint.")
            }
            let product = (version["Browser"] as? String ?? "").split(separator: "/")
            browserVersion = product.count == 2 ? "Chromium \(product[1].split(separator: ".").first ?? product[1])" : ""
            configureUserAgent(from: version)

            let conn = CDPConnection(url: wsURL)
            wireEvents(conn)
            try await conn.connect()
            guard gen == generation else { conn.close(); return }
            connection = conn

            try await conn.send("Target.setDiscoverTargets", ["discover": true])
            if !remoteHome.isEmpty {
                // "allow" keeps the server-suggested filename ("allowAndName"
                // would save every download under its GUID).
                _ = try? await conn.send("Browser.setDownloadBehavior", [
                    "behavior": "allow",
                    "downloadPath": "\(remoteHome)/Downloads",
                    "eventsEnabled": true
                ])
            }

            let targets = try await conn.send("Target.getTargets")
            guard gen == generation else { return }
            let pages = (targets["targetInfos"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "page" }
            for info in pages {
                upsertTab(from: info)
            }

            if let first = tabs.first {
                await activate(first.id)
                if tabs.count == 1, first.url == "about:blank" {
                    navigate(to: BrowserSearchEngine.current.homePage)
                }
            } else {
                await newTab()
            }
            guard gen == generation else { return }
            phase = .ready
            Task { await refreshServices() }
        } catch {
            guard gen == generation else { return }
            teardownLocal()
            phase = .failed(Self.describe(error))
        }
    }

    /// Closes the local side (WebSocket + tunnel). Chromium itself keeps running on
    /// the VPS unless the user opted out, in which case it's stopped too.
    func disconnect() {
        generation += 1
        teardownLocal()
        phase = .idle
        if !BrowserPreferences.keepRunningOnVPS {
            let server = self.server
            Task { _ = try? await ShellService.shared.ssh(server, command: Self.stopScript, timeout: 20) }
        }
    }

    /// Fully stops Chromium on the VPS (closes every tab there).
    func stopRemoteBrowser() async {
        generation += 1
        teardownLocal()
        phase = .working("Stopping Chromium on the VPS…")
        _ = try? await ShellService.shared.ssh(server, command: Self.stopScript, timeout: 20)
        phase = .idle
    }

    /// Restarts Chromium on the VPS and reconnects — the fix for a wedged browser.
    func restartRemoteBrowser() async {
        await stopRemoteBrowser()
        await connect()
    }

    func installBrowser() async {
        generation += 1
        let gen = generation
        teardownLocal()
        phase = .installing
        installLog = ""
        failureFix = nil
        do {
            let output = try await ShellService.shared.sshExpectingSuccess(server, command: Self.installScript, timeout: 1200)
            guard gen == generation else { return }
            installLog = output
            phase = .idle
            await connect()
        } catch {
            guard gen == generation else { return }
            failureFix = extractSudoFixCommand(from: error)
            phase = .failed("Installing Chromium failed.\n\n\(Self.describe(error))")
        }
    }

    /// Local cleanup only — used at app quit, where there's no time for a round trip.
    func shutdownLocal() {
        generation += 1
        teardownLocal()
        phase = .idle
    }

    private func teardownLocal() {
        connection?.close()
        connection = nil
        if let tunnel, tunnel.isRunning { tunnel.terminate() }
        tunnel = nil
        localPort = nil
        sessions.removeAll()
        activeSessionID = nil
        activeTabID = nil
        tabs = []
        isScreencasting = false
        canGoBack = false
        canGoForward = false
        isLoading = false
        currentURL = ""
        pageTitle = ""
        historyEntries = []
        lastFrame = nil
        dialog = nil
        viewportTask?.cancel()
    }

    private func connectionLost(_ message: String) {
        guard phase == .ready else { return }
        generation += 1
        teardownLocal()
        phase = .failed(message)
    }

    // MARK: Tunnel

    private func openTunnel(remotePort: Int, generation gen: Int) async throws -> [String: Any] {
        guard let port = Self.freeLocalPort() else {
            throw SessionError.message("Couldn't find a free local port for the tunnel.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        // A dedicated connection (ControlPath=none) rather than riding the shared
        // multiplexed master: the tunnel's lifetime is then exactly this process's
        // lifetime, and tearing it down can never disturb other SSH work.
        // ssh honours the *first* value given for an option, so these overrides
        // must come before the server's own `sshArgs`.
        process.arguments = [
            "ssh",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ExitOnForwardFailure=yes",
            "-N",
            "-L", "127.0.0.1:\(port):127.0.0.1:\(remotePort)"
        ] + server.sshArgs
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        process.environment = env
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        let errBuffer = PipeBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errBuffer.append(data) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let process, self.tunnel === process else { return }
                    self.connectionLost("The SSH tunnel to \(self.server.host) closed. Check your connection, then reconnect — the browser is still running on the VPS.")
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw SessionError.message("Couldn't start ssh: \(error.localizedDescription)")
        }
        tunnel = process
        localPort = port

        // Wait until the forward is live and Chrome answers through it.
        let deadline = Date().addingTimeInterval(20)
        let url = URL(string: "http://127.0.0.1:\(port)/json/version")!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        let probe = URLSession(configuration: config)
        defer { probe.invalidateAndCancel() }

        while Date() < deadline {
            guard gen == generation else { throw CancellationError() }
            if !process.isRunning {
                let stderr = String(data: errBuffer.snapshot(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw SessionError.message("The SSH tunnel couldn't be opened.\(stderr.isEmpty ? "" : " \(stderr)")")
            }
            if let (data, response) = try? await probe.data(from: url),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                return json
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw SessionError.message("Timed out waiting for the browser through the SSH tunnel.")
    }

    nonisolated static func freeLocalPort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return nil }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    // MARK: Events

    private func wireEvents(_ conn: CDPConnection) {
        conn.onEvent = { [weak self, weak conn] method, params, sessionID in
            if method == "Page.screencastFrame" {
                // Decode on the connection's background queue; only the finished
                // CGImage hops to the main thread.
                guard let ackID = params["sessionId"] as? Int else { return }
                conn?.fire("Page.screencastFrameAck", ["sessionId": ackID], sessionID: sessionID)
                guard let base64 = params["data"] as? String,
                      let data = Data(base64Encoded: base64),
                      let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
                let meta = params["metadata"] as? [String: Any]
                let width = (meta?["deviceWidth"] as? NSNumber)?.doubleValue ?? Double(image.width)
                let height = (meta?["deviceHeight"] as? NSNumber)?.doubleValue ?? Double(image.height)
                let frame = BrowserFrame(image: image, cssSize: CGSize(width: width, height: height))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.receive(frame, sessionID: sessionID) }
                }
                return
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handleEvent(method, params, sessionID: sessionID) }
            }
        }
        conn.onClose = { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.connectionLost("Lost the connection to the browser on \(self?.server.host ?? "the VPS"). It's most likely still running there — reconnect to pick up where you left off.")
                }
            }
        }
    }

    private func receive(_ frame: BrowserFrame, sessionID: String?) {
        guard sessionID != nil, sessionID == activeSessionID else { return }
        lastFrame = frame
        if viewportCSS != frame.cssSize { viewportCSS = frame.cssSize }
        frameSink?(frame)
    }

    private func handleEvent(_ method: String, _ params: CDPPayload, sessionID: String?) {
        switch method {
        case "Target.targetCreated":
            guard let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page",
                  let id = info["targetId"] as? String else { return }
            let isNew = !tabs.contains { $0.id == id }
            upsertTab(from: info)
            guard isNew, phase == .ready else { return }
            let openedByPage = info["openerId"] != nil
            // Pages opened by the page itself (target=_blank, window.open) come to
            // the front like in a desktop browser — except right after a ⌘-click,
            // which means "open in background tab".
            if openedByPage && Date().timeIntervalSince(lastModifiedClick) > 1.5 {
                Task { await activate(id) }
            }

        case "Target.targetInfoChanged":
            guard let info = params["targetInfo"] as? [String: Any], info["type"] as? String == "page" else { return }
            upsertTab(from: info)

        case "Target.targetDestroyed":
            guard let id = params["targetId"] as? String else { return }
            Task { await tabWentAway(id) }

        case "Target.targetCrashed":
            guard let id = params["targetId"] as? String, id == activeTabID else { return }
            showNotice("This tab crashed. Reload to try again.")

        case "Target.detachedFromTarget":
            if let sid = params["sessionId"] as? String,
               let target = sessions.first(where: { $0.value == sid })?.key {
                sessions[target] = nil
                if activeSessionID == sid {
                    activeSessionID = nil
                    isScreencasting = false
                }
            }

        case "Page.frameNavigated":
            guard sessionID == activeSessionID,
                  let frame = params["frame"] as? [String: Any], frame["parentId"] == nil else { return }
            Task { await refreshHistory() }

        case "Page.navigatedWithinDocument":
            guard sessionID == activeSessionID else { return }
            Task { await refreshHistory() }

        case "Page.frameStartedLoading":
            if sessionID == activeSessionID, params["frameId"] as? String == activeTabID { isLoading = true }

        case "Page.frameStoppedLoading":
            if sessionID == activeSessionID, params["frameId"] as? String == activeTabID {
                isLoading = false
                Task { await refreshHistory() }
            }

        case "Page.loadEventFired":
            if sessionID == activeSessionID { isLoading = false }

        case "Page.javascriptDialogOpening":
            guard let sessionID else { return }
            dialog = BrowserDialog(
                sessionID: sessionID,
                kind: params["type"] as? String ?? "alert",
                message: params["message"] as? String ?? "",
                defaultPrompt: params["defaultPrompt"] as? String ?? "",
                origin: URL(string: params["url"] as? String ?? "")?.host ?? ""
            )

        case "Page.javascriptDialogClosed":
            if dialog?.sessionID == sessionID { dialog = nil }

        case "Browser.downloadWillBegin":
            let name = params["suggestedFilename"] as? String ?? "file"
            showNotice("Downloading “\(name)” to ~/Downloads on the VPS…")

        case "Browser.downloadProgress":
            switch params["state"] as? String {
            case "completed": showNotice("Download finished — saved to ~/Downloads on \(server.host).")
            case "canceled": showNotice("Download canceled.")
            default: break
            }

        default:
            break
        }
    }

    private func upsertTab(from info: [String: Any]) {
        guard let id = info["targetId"] as? String else { return }
        let title = info["title"] as? String ?? ""
        let url = info["url"] as? String ?? ""
        if let index = tabs.firstIndex(where: { $0.id == id }) {
            if tabs[index].title != title || tabs[index].url != url {
                tabs[index].title = title
                tabs[index].url = url
            }
        } else {
            tabs.append(BrowserTab(id: id, title: title, url: url))
        }
        if id == activeTabID {
            if pageTitle != title { pageTitle = title }
            if currentURL != url { currentURL = url }
        }
    }

    private func tabWentAway(_ id: String) async {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        sessions[id] = nil
        guard activeTabID == id else { return }
        activeTabID = nil
        activeSessionID = nil
        isScreencasting = false
        if tabs.isEmpty {
            await newTab()
        } else {
            await activate(tabs[min(index, tabs.count - 1)].id)
        }
    }

    // MARK: Tabs

    func activate(_ targetID: String) async {
        guard let conn = connection else { return }
        if let old = activeSessionID, isScreencasting {
            conn.fire("Page.stopScreencast", sessionID: old)
        }
        isScreencasting = false

        let sessionID: String
        if let existing = sessions[targetID] {
            sessionID = existing
        } else {
            guard let result = try? await conn.send("Target.attachToTarget", ["targetId": targetID, "flatten": true]),
                  let sid = result["sessionId"] as? String else {
                showNotice("Couldn't open that tab.")
                return
            }
            sessionID = sid
            sessions[targetID] = sid
            await configure(sessionID: sid)
        }

        activeTabID = targetID
        activeSessionID = sessionID
        lastFrame = nil
        dialog = dialog?.sessionID == sessionID ? dialog : nil
        if let tab = tabs.first(where: { $0.id == targetID }) {
            currentURL = tab.url
            pageTitle = tab.title
        }
        conn.fire("Target.activateTarget", ["targetId": targetID])
        await applyViewport()
        await refreshHistory()
    }

    private func configure(sessionID sid: String) async {
        guard let conn = connection else { return }
        _ = try? await conn.send("Page.enable", sessionID: sid)
        // Headless pages otherwise believe they never have focus: no caret in text
        // fields, no :focus styles, and some sites refuse keyboard input.
        conn.fire("Emulation.setFocusEmulationEnabled", ["enabled": true], sessionID: sid)
        if let userAgent {
            var params: [String: Any] = ["userAgent": userAgent, "acceptLanguage": Self.acceptLanguage]
            if let userAgentMetadata { params["userAgentMetadata"] = userAgentMetadata }
            if (try? await conn.send("Emulation.setUserAgentOverride", params, sessionID: sid)) == nil {
                conn.fire("Emulation.setUserAgentOverride", ["userAgent": userAgent, "acceptLanguage": Self.acceptLanguage], sessionID: sid)
            }
        }
    }

    func newTab(url: String? = nil) async {
        guard let conn = connection else { return }
        let target = url ?? BrowserSearchEngine.current.homePage
        guard let result = try? await conn.send("Target.createTarget", ["url": target]),
              let id = result["targetId"] as? String else {
            showNotice("Couldn't open a new tab.")
            return
        }
        if tabs.contains(where: { $0.id == id }) {
            await activate(id)
        } else {
            // targetCreated may land after this reply — add the tab now; the event
            // will then just refresh its title/URL.
            tabs.append(BrowserTab(id: id, title: "", url: target))
            await activate(id)
        }
    }

    func closeTab(_ id: String) {
        guard let conn = connection else { return }
        if tabs.count == 1 {
            // Never leave the browser with zero tabs — reset the last one instead.
            navigate(to: BrowserSearchEngine.current.homePage)
            return
        }
        conn.fire("Target.closeTarget", ["targetId": id])
    }

    // MARK: Navigation

    func navigate(to input: String) {
        guard let conn = connection, let sid = activeSessionID else { return }
        let url = Self.normalizedURL(from: input)
        currentURL = url
        isLoading = true
        conn.fire("Page.navigate", ["url": url], sessionID: sid)
    }

    func goBack() {
        guard canGoBack, historyIndex > 0, historyIndex - 1 < historyEntries.count else { return }
        go(toEntry: historyEntries[historyIndex - 1].id)
    }

    func goForward() {
        guard canGoForward, historyIndex + 1 < historyEntries.count else { return }
        go(toEntry: historyEntries[historyIndex + 1].id)
    }

    private func go(toEntry id: Int) {
        guard let conn = connection, let sid = activeSessionID else { return }
        conn.fire("Page.navigateToHistoryEntry", ["entryId": id], sessionID: sid)
    }

    func reload(ignoreCache: Bool = false) {
        guard let conn = connection, let sid = activeSessionID else { return }
        conn.fire("Page.reload", ["ignoreCache": ignoreCache], sessionID: sid)
    }

    func stopLoading() {
        guard let conn = connection, let sid = activeSessionID else { return }
        conn.fire("Page.stopLoading", sessionID: sid)
        isLoading = false
    }

    private func refreshHistory() async {
        guard let conn = connection, let sid = activeSessionID else { return }
        guard let result = try? await conn.send("Page.getNavigationHistory", sessionID: sid),
              sid == activeSessionID else { return }
        let index = result["currentIndex"] as? Int ?? 0
        let entries = (result["entries"] as? [[String: Any]] ?? []).map {
            (id: $0["id"] as? Int ?? 0, url: $0["url"] as? String ?? "", title: $0["title"] as? String ?? "")
        }
        historyEntries = entries
        historyIndex = index
        canGoBack = index > 0
        canGoForward = index < entries.count - 1
        if entries.indices.contains(index) {
            currentURL = entries[index].url
            if !entries[index].title.isEmpty { pageTitle = entries[index].title }
        }
    }

    // MARK: Viewport, zoom, visibility

    func viewportChanged(size: CGSize, backingScale: CGFloat) {
        guard size.width >= 50, size.height >= 50 else { return }
        let changed = abs(size.width - viewSize.width) >= 1 || abs(size.height - viewSize.height) >= 1 || backingScale != self.backingScale
        guard changed else { return }
        viewSize = size
        self.backingScale = backingScale
        // Live window resizes fire this every frame — settle first, then resize
        // the remote viewport once.
        viewportTask?.cancel()
        viewportTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            await self?.applyViewport()
        }
    }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        Task { await applyViewport() }
    }

    func setZoom(_ value: Double) {
        zoom = min(max(value, Self.zoomLevels.first!), Self.zoomLevels.last!)
        Task { await applyViewport() }
    }

    func zoomIn() {
        if let next = Self.zoomLevels.first(where: { $0 > zoom + 0.001 }) { setZoom(next) }
    }

    func zoomOut() {
        if let previous = Self.zoomLevels.last(where: { $0 < zoom - 0.001 }) { setZoom(previous) }
    }

    func qualityChanged() {
        Task { await applyViewport() }
    }

    /// Sizes the remote page to exactly the on-screen canvas (divided by zoom, so
    /// zooming re-lays-out the page like real browser zoom), then (re)starts the
    /// screencast at the matching pixel size. Paused entirely while hidden so a
    /// background tab costs no bandwidth.
    private func applyViewport() async {
        guard let conn = connection, let sid = activeSessionID else { return }
        if !isVisible {
            if isScreencasting {
                conn.fire("Page.stopScreencast", sessionID: sid)
                isScreencasting = false
            }
            return
        }
        let quality = BrowserQuality.current
        let pixelScale = quality.pixelScale(backingScale: backingScale)
        let cssWidth = max(200, Int((viewSize.width / zoom).rounded()))
        let cssHeight = max(150, Int((viewSize.height / zoom).rounded()))
        _ = try? await conn.send("Emulation.setDeviceMetricsOverride", [
            "width": cssWidth,
            "height": cssHeight,
            "deviceScaleFactor": Double(pixelScale) * zoom,
            "mobile": false,
            "screenWidth": cssWidth,
            "screenHeight": cssHeight
        ], sessionID: sid)
        guard sid == activeSessionID, isVisible else { return }
        if isScreencasting { conn.fire("Page.stopScreencast", sessionID: sid) }
        conn.fire("Page.startScreencast", [
            "format": "jpeg",
            "quality": quality.jpegQuality,
            "maxWidth": Int(viewSize.width * pixelScale),
            "maxHeight": Int(viewSize.height * pixelScale),
            "everyNthFrame": 1
        ], sessionID: sid)
        isScreencasting = true
    }

    // MARK: Input

    func dispatchMouse(_ params: [String: Any], modifiedClick: Bool = false) {
        guard let conn = connection, let sid = activeSessionID else { return }
        if modifiedClick { lastModifiedClick = Date() }
        conn.fire("Input.dispatchMouseEvent", params, sessionID: sid)
    }

    func dispatchKey(_ params: [String: Any]) {
        guard let conn = connection, let sid = activeSessionID else { return }
        conn.fire("Input.dispatchKeyEvent", params, sessionID: sid)
    }

    func insertText(_ text: String) {
        guard let conn = connection, let sid = activeSessionID, !text.isEmpty else { return }
        conn.fire("Input.insertText", ["text": text], sessionID: sid)
    }

    /// Evaluates JavaScript in the active tab and returns its by-value result.
    func evaluate(_ expression: String, timeout: TimeInterval = 5) async -> Any? {
        guard let conn = connection, let sid = activeSessionID else { return nil }
        guard let result = try? await conn.send("Runtime.evaluate", [
            "expression": expression,
            "returnByValue": true,
            "userGesture": true
        ], sessionID: sid, timeout: timeout) else { return nil }
        return (result["result"] as? [String: Any])?["value"]
    }

    func copySelection() async -> Bool {
        guard let text = await evaluate(Self.selectionScript) as? String, !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return true
    }

    func respondToDialog(accept: Bool, text: String? = nil) {
        guard let dialog, let conn = connection else { self.dialog = nil; return }
        var params: [String: Any] = ["accept": accept]
        if let text { params["promptText"] = text }
        conn.fire("Page.handleJavaScriptDialog", params, sessionID: dialog.sessionID)
        self.dialog = nil
    }

    func clearBrowsingData() async {
        guard let conn = connection, let sid = activeSessionID else { return }
        _ = try? await conn.send("Network.clearBrowserCookies", sessionID: sid)
        _ = try? await conn.send("Network.clearBrowserCache", sessionID: sid)
        _ = try? await conn.send("Storage.clearDataForOrigin", ["origin": "*", "storageTypes": "all"], sessionID: sid)
        showNotice("Cleared cookies and cache.")
        reload()
    }

    func showNotice(_ text: String) {
        notice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Services on the VPS

    /// Lists TCP ports listening on the VPS — the browser runs *on* the VPS, so
    /// http://localhost:<port> reaches services that aren't exposed publicly.
    func refreshServices() async {
        loadingServices = true
        defer { loadingServices = false }
        let command = "ss -Hltnp 2>/dev/null || ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null"
        guard let result = try? await ShellService.shared.ssh(server, command: command, timeout: 15) else { return }
        services = Self.parseListening(result.stdout, excluding: remotePort)
    }

    nonisolated static func parseListening(_ output: String, excluding: Int?) -> [ListeningService] {
        var byPort: [Int: ListeningService] = [:]
        for raw in output.split(separator: "\n") {
            let line = String(raw)
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let local = columns.first(where: { col in
                guard let colon = col.lastIndex(of: ":") else { return false }
                return Int(col[col.index(after: colon)...]) != nil && (col.contains(".") || col.contains("[") || col.hasPrefix("*") || col.contains("::"))
            }), let colon = local.lastIndex(of: ":"),
                  let port = Int(local[local.index(after: colon)...]) else { continue }
            guard line.contains("LISTEN") || line.hasPrefix("tcp") else { continue }
            if port == excluding || port == 22 || port == 53 { continue }
            let host = String(local[..<colon])
            let loopback = host.hasPrefix("127.") || host == "[::1]" || host == "::1" || host.hasPrefix("localhost")
            var process: String?
            if let start = line.range(of: "((\"")?.upperBound, let end = line[start...].firstIndex(of: "\"") {
                process = String(line[start..<end])
            } else if let slash = columns.last?.firstIndex(of: "/"), let last = columns.last {
                process = String(last[last.index(after: slash)...])
            }
            let existing = byPort[port]
            byPort[port] = ListeningService(port: port,
                                            process: process ?? existing?.process,
                                            isLoopbackOnly: (existing?.isLoopbackOnly ?? true) && loopback)
        }
        return byPort.values.sorted { $0.port < $1.port }
    }

    // MARK: Helpers

    private func configureUserAgent(from version: [String: Any]) {
        guard let raw = version["User-Agent"] as? String else { return }
        userAgent = raw.replacingOccurrences(of: "HeadlessChrome", with: "Chrome")
        let full = (version["Browser"] as? String)?.split(separator: "/").last.map(String.init) ?? ""
        let major = full.split(separator: ".").first.map(String.init) ?? ""
        guard !major.isEmpty else { userAgentMetadata = nil; return }
        let isArm = raw.contains("aarch64") || raw.contains("arm")
        userAgentMetadata = [
            "brands": [
                ["brand": "Chromium", "version": major],
                ["brand": "Not_A Brand", "version": "24"]
            ],
            "fullVersionList": [
                ["brand": "Chromium", "version": full],
                ["brand": "Not_A Brand", "version": "24.0.0.0"]
            ],
            "fullVersion": full,
            "platform": "Linux",
            "platformVersion": "",
            "architecture": isArm ? "arm" : "x86",
            "model": "",
            "mobile": false,
            "bitness": "64"
        ]
    }

    private static var acceptLanguage: String {
        let languages = Locale.preferredLanguages.prefix(3)
        guard !languages.isEmpty else { return "en-US,en;q=0.9" }
        return languages.enumerated().map { index, lang in
            index == 0 ? lang : "\(lang);q=\(String(format: "%.1f", 1 - Double(index) * 0.1))"
        }.joined(separator: ",")
    }

    nonisolated static func normalizedURL(from input: String) -> String {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return "about:blank" }
        let lower = text.lowercased()
        let schemes = ["http://", "https://", "about:", "data:", "file://", "chrome://", "view-source:", "ftp://", "ws://", "wss://"]
        if schemes.contains(where: { lower.hasPrefix($0) }) { return text }
        if !text.contains(" ") {
            let hostPort = String(text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            var host = hostPort
            var hasPort = false
            if hostPort.hasPrefix("[") {
                if let close = hostPort.firstIndex(of: "]") { host = String(hostPort[...close]) }
                return "http://\(text)"
            } else if let colon = hostPort.lastIndex(of: ":") {
                let port = hostPort[hostPort.index(after: colon)...]
                if !port.isEmpty, port.allSatisfy(\.isNumber) {
                    host = String(hostPort[..<colon])
                    hasPort = true
                }
            }
            let hostLower = host.lowercased()
            let isIPv4 = host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
            if hostLower == "localhost" || hostLower.hasSuffix(".localhost") || isIPv4 || hostLower.hasSuffix(".local") || hostLower.hasSuffix(".internal") {
                return "http://\(text)"
            }
            if hasPort && !host.isEmpty && !host.contains(" ") {
                return "http://\(text)"
            }
            if let dot = host.lastIndex(of: "."), dot != host.startIndex {
                let tld = host[host.index(after: dot)...]
                if tld.count >= 2, tld.allSatisfy({ $0.isLetter || $0 == "-" || $0.isNumber }), tld.contains(where: \.isLetter) {
                    return "https://\(text)"
                }
            }
        }
        return BrowserSearchEngine.current.searchURL(for: text)
    }

    nonisolated static func parseMarkers(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("VPSM_"), let eq = trimmed.firstIndex(of: "=") else { continue }
            values[String(trimmed[..<eq])] = String(trimmed[trimmed.index(after: eq)...])
        }
        return values
    }

    nonisolated static func logSection(_ output: String) -> String {
        guard let range = output.range(of: "VPSM_LOG_BEGIN") else { return "" }
        return output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").suffix(12).joined(separator: "\n")
    }

    private static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        return error.localizedDescription
    }

    enum SessionError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let text): return text }
        }
    }

    // MARK: Page scripts

    static let selectionScript = """
    (() => {
      const el = document.activeElement;
      if (el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && /^(text|search|url|tel|password|email|number)$/i.test(el.type)))) {
        try { const v = el.value.substring(el.selectionStart, el.selectionEnd); if (v) return v; } catch (e) {}
      }
      const s = window.getSelection ? String(window.getSelection()) : '';
      return s;
    })()
    """

    static func cursorScript(x: Double, y: Double) -> String {
        """
        (() => {
          const el = document.elementFromPoint(\(x), \(y));
          if (!el) return 'default';
          const c = getComputedStyle(el).cursor;
          if (c && c !== 'auto') return c;
          if (el.isContentEditable || el.matches('textarea, input:not([type=button]):not([type=submit]):not([type=reset]):not([type=checkbox]):not([type=radio]):not([type=range]):not([type=color]):not([type=file]):not([type=image])')) return 'text';
          return 'default';
        })()
        """
    }

    static func selectProbeScript(x: Double, y: Double) -> String {
        """
        (() => {
          const el = document.activeElement;
          if (!el || el.tagName !== 'SELECT' || el.multiple || el.disabled) return null;
          const r = el.getBoundingClientRect();
          if (\(x) < r.left - 1 || \(x) > r.right + 1 || \(y) < r.top - 1 || \(y) > r.bottom + 1) return null;
          return JSON.stringify({
            selected: el.selectedIndex,
            left: r.left, bottom: r.bottom,
            options: Array.from(el.options).map(o => ({
              label: o.label || o.text,
              disabled: o.disabled,
              group: (o.parentElement && o.parentElement.tagName === 'OPTGROUP') ? o.parentElement.label : null
            }))
          });
        })()
        """
    }

    static func selectChooseScript(index: Int) -> String {
        """
        (() => {
          const el = document.activeElement;
          if (!el || el.tagName !== 'SELECT') return false;
          el.selectedIndex = \(index);
          el.dispatchEvent(new Event('input', { bubbles: true }));
          el.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        })()
        """
    }

    // MARK: VPS scripts

    /// Finds Chrome/Chromium, reuses an already-running instance for our profile
    /// or launches a fresh headless one, and reports the DevTools port.
    /// Output is `VPSM_KEY=value` lines so login-shell noise can't confuse parsing.
    static let launchScript = #"""
    VPSM_BIN=""
    for c in google-chrome-stable google-chrome chromium chromium-browser; do
      p="$(type -P "$c" 2>/dev/null)"
      [ -n "$p" ] || continue
      if "$p" --version >/dev/null 2>&1; then VPSM_BIN="$p"; break; fi
    done
    if [ -z "$VPSM_BIN" ] && [ -x /snap/bin/chromium ]; then VPSM_BIN=/snap/bin/chromium; fi
    if [ -z "$VPSM_BIN" ]; then echo "VPSM_ERROR=not_installed"; exit 0; fi

    VPSM_BASE="$HOME/.vpsmanager/browser"
    case "$VPSM_BIN" in
      /snap/*) VPSM_BASE="$HOME/snap/chromium/common/vpsmanager-browser" ;;
      *chromium*)
        if [ -x /snap/bin/chromium ] && [ "$(head -c 1 "$VPSM_BIN" 2>/dev/null)" = "#" ] && grep -qs snap "$VPSM_BIN"; then
          VPSM_BASE="$HOME/snap/chromium/common/vpsmanager-browser"
        fi ;;
    esac
    VPSM_PROFILE="$VPSM_BASE/profile"
    mkdir -p "$VPSM_PROFILE" "$HOME/Downloads"

    vpsm_pids() {
      if command -v pgrep >/dev/null 2>&1; then
        pgrep -u "$(id -u)" -f -- "--user-data-dir=$VPSM_PROFILE"
      else
        ps -u "$(id -u)" -o pid=,args= | grep -F -- "--user-data-dir=$VPSM_PROFILE" | grep -v grep | awk '{print $1}'
      fi
    }

    VPSM_PORTFILE="$VPSM_PROFILE/DevToolsActivePort"
    vpsm_start() {
      if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$VPSM_BIN" "$@" about:blank > "$VPSM_BASE/chrome.log" 2>&1 < /dev/null &
      else
        nohup "$VPSM_BIN" "$@" about:blank > "$VPSM_BASE/chrome.log" 2>&1 < /dev/null &
      fi
    }
    vpsm_wait() {
      i=0
      while [ $i -lt 200 ]; do
        [ -s "$VPSM_PORTFILE" ] && return 0
        # Bail out early if Chromium already died instead of waiting the full time.
        if [ $i -gt 8 ] && [ -z "$(vpsm_pids)" ]; then return 1; fi
        sleep 0.25
        i=$((i + 1))
      done
      return 1
    }
    vpsm_clean() {
      for pid in $(vpsm_pids); do kill "$pid" 2>/dev/null; done
      sleep 0.3
      rm -f "$VPSM_PORTFILE" "$VPSM_PROFILE/SingletonLock" "$VPSM_PROFILE/SingletonSocket" "$VPSM_PROFILE/SingletonCookie"
    }

    if [ -n "$(vpsm_pids)" ] && [ -s "$VPSM_PORTFILE" ]; then
      echo "VPSM_STATE=reused"
      if command -v pgrep >/dev/null 2>&1 && pgrep -u "$(id -u)" -f -- "--user-data-dir=$VPSM_PROFILE .*--no-sandbox" >/dev/null 2>&1; then
        echo "VPSM_SANDBOX=off"
      fi
    else
      vpsm_clean
      VPSM_VER="$("$VPSM_BIN" --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){3}' | head -n1)"
      VPSM_MAJOR="${VPSM_VER%%.*}"
      [ -n "$VPSM_MAJOR" ] || VPSM_MAJOR=120
      case "$(uname -m)" in aarch64|arm64) VPSM_ARCH="aarch64" ;; *) VPSM_ARCH="x86_64" ;; esac
      VPSM_UA="Mozilla/5.0 (X11; Linux $VPSM_ARCH) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/$VPSM_MAJOR.0.0.0 Safari/537.36"
      set -- --headless=new --remote-debugging-port=0 --remote-debugging-address=127.0.0.1 \
        "--user-data-dir=$VPSM_PROFILE" --no-first-run --no-default-browser-check \
        --disable-gpu --disable-dev-shm-usage --password-store=basic --window-size=1280,800 \
        --force-color-profile=srgb --disable-features=Translate,MediaRouter,OptimizationHints \
        --hide-crash-restore-bubble "--user-agent=$VPSM_UA"
      if [ "$(id -u)" = "0" ]; then
        set -- "$@" --no-sandbox
        echo "VPSM_SANDBOX=off"
      fi
      vpsm_start "$@"
      if ! vpsm_wait && [ "$(id -u)" != "0" ] && grep -qi "sandbox" "$VPSM_BASE/chrome.log" 2>/dev/null; then
        # Containers and Ubuntu 23.10+ (AppArmor) often block the user-namespace
        # sandbox. Retry without it rather than not working at all.
        vpsm_clean
        set -- "$@" --no-sandbox
        vpsm_start "$@"
        vpsm_wait
        echo "VPSM_SANDBOX=off"
      fi
      echo "VPSM_STATE=launched"
    fi
    if [ ! -s "$VPSM_PORTFILE" ]; then
      echo "VPSM_ERROR=launch_failed"
      echo "VPSM_LOG_BEGIN"
      tail -n 25 "$VPSM_BASE/chrome.log" 2>/dev/null
      exit 0
    fi
    echo "VPSM_PORT=$(head -n 1 "$VPSM_PORTFILE")"
    echo "VPSM_HOME=$HOME"
    echo "VPSM_BASE=$VPSM_BASE"
    echo "VPSM_BIN=$VPSM_BIN"
    """#

    static let stopScript = #"""
    for d in "$HOME/.vpsmanager/browser/profile" "$HOME/snap/chromium/common/vpsmanager-browser/profile"; do
      if command -v pkill >/dev/null 2>&1; then
        pkill -u "$(id -u)" -f -- "--user-data-dir=$d" 2>/dev/null
      else
        for pid in $(ps -u "$(id -u)" -o pid=,args= | grep -F -- "--user-data-dir=$d" | grep -v grep | awk '{print $1}'); do kill "$pid" 2>/dev/null; done
      fi
      rm -f "$d/DevToolsActivePort"
    done
    true
    """#

    /// Installs a browser with the distro's package manager. On amd64 Debian/Ubuntu
    /// it uses Google's official .deb (Ubuntu's own `chromium` is a snap shim that
    /// often isn't usable on servers); elsewhere the distro's Chromium package.
    static let installScript = #"""
    set -e
    SUDO=""
    if [ "$(id -u)" != "0" ]; then SUDO="sudo -n"; fi
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive
      APT="$SUDO env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y"
      $APT update
      ARCH="$(dpkg --print-architecture)"
      if [ "$ARCH" = "amd64" ]; then
        TMP="$(mktemp -d)"
        chmod 755 "$TMP"
        if command -v curl >/dev/null 2>&1; then
          curl -fsSL -o "$TMP/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        else
          $APT install --no-install-recommends wget ca-certificates
          wget -q -O "$TMP/chrome.deb" https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
        fi
        chmod 644 "$TMP/chrome.deb"
        $APT install "$TMP/chrome.deb" fonts-liberation fonts-noto-color-emoji
        rm -rf "$TMP"
      else
        $APT install chromium fonts-liberation fonts-noto-color-emoji || $APT install chromium-browser fonts-liberation fonts-noto-color-emoji
        $APT install chromium-sandbox 2>/dev/null || true
      fi
    elif command -v dnf >/dev/null 2>&1; then
      $SUDO dnf install -y chromium || { $SUDO dnf install -y epel-release && $SUDO dnf install -y chromium; }
    elif command -v yum >/dev/null 2>&1; then
      $SUDO yum install -y epel-release || true
      $SUDO yum install -y chromium
    elif command -v pacman >/dev/null 2>&1; then
      $SUDO pacman -Sy --noconfirm chromium noto-fonts
    elif command -v apk >/dev/null 2>&1; then
      $SUDO apk add --no-cache chromium font-noto
    elif command -v zypper >/dev/null 2>&1; then
      $SUDO zypper --non-interactive install chromium
    else
      echo "No supported package manager found (apt, dnf, yum, pacman, apk, zypper)." >&2
      exit 1
    fi
    echo "VPSM_INSTALLED=1"
    """#
}

// MARK: - Registry

/// Keeps one browser session per server alive for the app's lifetime, so
/// switching tabs, switching servers, or closing and reopening a window never
/// drops the connection.
@MainActor
final class RemoteBrowserManager {
    static let shared = RemoteBrowserManager()
    private var sessions: [UUID: RemoteBrowserSession] = [:]

    func session(for server: Server) -> RemoteBrowserSession {
        if let existing = sessions[server.id] {
            if existing.server != server { existing.server = server }
            return existing
        }
        let session = RemoteBrowserSession(server: server)
        sessions[server.id] = session
        return session
    }

    func isConnected(_ serverID: UUID) -> Bool {
        sessions[serverID]?.isConnected ?? false
    }

    /// Called at quit: closes local tunnels synchronously. If the user turned off
    /// "keep running", also fires (without waiting) the remote stop command.
    func shutdownAll() {
        for session in sessions.values {
            let wasConnected = session.isConnected
            session.shutdownLocal()
            if wasConnected && !BrowserPreferences.keepRunningOnVPS {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                let escaped = RemoteBrowserSession.stopScript.replacingOccurrences(of: "'", with: "'\\''")
                process.arguments = ["ssh"] + session.server.sshArgs + ["bash -lc '\(escaped)'"]
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
            }
        }
    }
}
