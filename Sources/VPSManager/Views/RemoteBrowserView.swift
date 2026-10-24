import SwiftUI
import AppKit

/// The Browser tab: a real Chromium running on the VPS, shown and controlled
/// from here. See `RemoteBrowserSession` for how the pieces connect.
struct RemoteBrowserView: View {
    let server: Server
    /// False while another tab is showing — the view stays mounted (so the
    /// session and its last frame survive tab switches) but streaming pauses.
    let isActive: Bool

    @ObservedObject private var session: RemoteBrowserSession
    @State private var address = ""
    @FocusState private var addressFocused: Bool
    @State private var showingServices = false
    @State private var promptText = ""
    @State private var hoveredTab: String?
    @AppStorage(BrowserQuality.storageKey) private var qualityRaw = BrowserQuality.sharp.rawValue

    init(server: Server, isActive: Bool) {
        self.server = server
        self.isActive = isActive
        _session = ObservedObject(wrappedValue: RemoteBrowserManager.shared.session(for: server))
    }

    var body: some View {
        Group {
            if session.phase == .ready {
                browserChrome
            } else {
                setupState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .canvasBackground()
            }
        }
        .onAppear {
            session.setVisible(isActive)
            address = displayAddress(session.currentURL)
        }
        .onDisappear { session.setVisible(false) }
        .onChange(of: isActive) { _, active in session.setVisible(active) }
        .onChange(of: session.currentURL) { _, url in
            if !addressFocused { address = displayAddress(url) }
        }
        .onChange(of: addressFocused) { _, focused in
            if !focused { address = displayAddress(session.currentURL) }
        }
        .onChange(of: qualityRaw) { _, _ in session.qualityChanged() }
        .sheet(item: $session.dialog, onDismiss: {
            if session.dialog != nil { session.respondToDialog(accept: false) }
        }) { dialog in
            dialogSheet(dialog)
        }
    }

    // MARK: - Browser chrome

    private var browserChrome: some View {
        VStack(spacing: 0) {
            tabStrip
            toolbar
            Divider()
            ZStack(alignment: .top) {
                BrowserCanvas(session: session) { addressFocused = true }
                if session.isLoading {
                    LoadingBar()
                }
            }
            .overlay(alignment: .bottom) {
                if let notice = session.notice {
                    Text(notice)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.78), in: Capsule())
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.notice)
            Divider()
            statusBar
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(session.tabs) { tab in
                        tabChip(tab)
                    }
                }
                .padding(.vertical, 1)
            }
            Button {
                Task { await session.newTab() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New Tab (⌘T)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Theme.surfaceAlt)
    }

    private func tabChip(_ tab: BrowserTab) -> some View {
        let active = tab.id == session.activeTabID
        let hovered = hoveredTab == tab.id
        return HStack(spacing: 7) {
            if active && session.isLoading {
                ProgressView().controlSize(.mini).frame(width: 14, height: 14)
            } else {
                Image(systemName: tab.url.hasPrefix("https://") ? "lock.fill" : "globe")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(active ? Theme.accent : .secondary)
                    .frame(width: 14, height: 14)
            }
            Text(tab.displayTitle)
                .font(.callout.weight(active ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(active ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                session.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(active || hovered ? 1 : 0)
            .help("Close Tab (⌘W)")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 190, height: 30)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(active ? Theme.surface : (hovered ? Theme.stroke.opacity(0.5) : .clear))
                .shadow(color: .black.opacity(active ? 0.06 : 0), radius: 2, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(active ? Theme.stroke : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await session.activate(tab.id) } }
        .onHover { hoveredTab = $0 ? tab.id : (hoveredTab == tab.id ? nil : hoveredTab) }
        .help(tab.url)
        .contextMenu {
            Button("Reload Tab") {
                Task {
                    await session.activate(tab.id)
                    session.reload()
                }
            }
            Button("Duplicate Tab") { Task { await session.newTab(url: tab.url) } }
            Button("Copy Address") { copyToPasteboard(tab.url) }
            Divider()
            Button("Close Tab") { session.closeTab(tab.id) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", help: "Back (⌘[)", enabled: session.canGoBack) { session.goBack() }
            navButton("chevron.right", help: "Forward (⌘])", enabled: session.canGoForward) { session.goForward() }
            if session.isLoading {
                navButton("xmark", help: "Stop") { session.stopLoading() }
            } else {
                navButton("arrow.clockwise", help: "Reload (⌘R)") { session.reload() }
            }

            addressField
                .padding(.horizontal, 4)

            Button {
                showingServices.toggle()
            } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .frame(width: 28, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Services listening on \(server.host)")
            .popover(isPresented: $showingServices, arrowEdge: .bottom) {
                servicesPopover
            }

            moreMenu
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.surface)
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.4))
        .disabled(!enabled)
        .help(help)
    }

    private var addressField: some View {
        HStack(spacing: 8) {
            Image(systemName: addressIcon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(addressIconTint)
            TextField("Search or enter an address", text: $address)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($addressFocused)
                .onSubmit {
                    session.navigate(to: address)
                    addressFocused = false
                }
                .onExitCommand {
                    address = displayAddress(session.currentURL)
                    addressFocused = false
                }
            if session.zoom != 1 {
                Button {
                    session.setZoom(1)
                } label: {
                    Text("\(Int((session.zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Reset zoom (⌘0)")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(Theme.surfaceAlt, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(addressFocused ? Theme.accent : Theme.stroke, lineWidth: addressFocused ? 2 : 1)
        )
    }

    private var addressIcon: String {
        let url = session.currentURL
        if url.hasPrefix("https://") { return "lock.fill" }
        if url.hasPrefix("http://localhost") || url.hasPrefix("http://127.") { return "server.rack" }
        if url.hasPrefix("http://") { return "exclamationmark.triangle.fill" }
        return "magnifyingglass"
    }

    private var addressIconTint: Color {
        let url = session.currentURL
        if url.hasPrefix("https://") { return Theme.success }
        if url.hasPrefix("http://localhost") || url.hasPrefix("http://127.") { return Theme.accent }
        if url.hasPrefix("http://") { return Theme.warning }
        return .secondary
    }

    private var moreMenu: some View {
        Menu {
            Button("New Tab") { Task { await session.newTab() } }
            Button("Copy Page Address") { copyToPasteboard(session.currentURL) }
            Button("Open Address on This Mac") {
                if let url = URL(string: session.currentURL), url.scheme?.hasPrefix("http") == true {
                    NSWorkspace.shared.open(url)
                }
            }
            .disabled(!(session.currentURL.hasPrefix("http")))

            Divider()

            Menu("Zoom (\(Int((session.zoom * 100).rounded()))%)") {
                Button("Zoom In") { session.zoomIn() }
                Button("Zoom Out") { session.zoomOut() }
                Button("Actual Size") { session.setZoom(1) }
            }
            Picker("Stream Quality", selection: $qualityRaw) {
                ForEach(BrowserQuality.allCases) { quality in
                    Text(quality.title).tag(quality.rawValue)
                }
            }

            Divider()

            Button("Hard Reload") { session.reload(ignoreCache: true) }
            Button("Clear Cookies & Cache") { Task { await session.clearBrowsingData() } }

            Divider()

            Button("Restart Browser on VPS") { Task { await session.restartRemoteBrowser() } }
            Button("Stop Browser on VPS", role: .destructive) { Task { await session.stopRemoteBrowser() } }
            Button("Disconnect") { session.disconnect() }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private var servicesPopover: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Services on \(server.nickname)").font(.headline)
                    Text("Ports listening on the VPS — open them as localhost.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if session.loadingServices {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await session.refreshServices() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                }
            }
            .padding(14)
            Divider()
            if session.services.isEmpty {
                Text(session.loadingServices ? "Scanning…" : "No listening TCP services found.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(session.services) { service in
                            serviceRow(service)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 300)
            }
        }
        .frame(width: 320)
        .task { await session.refreshServices() }
    }

    private func serviceRow(_ service: ListeningService) -> some View {
        Button {
            session.navigate(to: "http://localhost:\(service.port)")
            showingServices = false
        } label: {
            HStack(spacing: 10) {
                IconTile(systemImage: service.isLoopbackOnly ? "lock.shield" : "network", size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "localhost:\(service.port)")
                        .font(.system(.callout, design: .monospaced).weight(.medium))
                    Text([service.process, service.isLoopbackOnly ? "VPS only" : "Public"].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowButtonStyle())
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.success).frame(width: 7, height: 7)
            Text("Running on \(server.host)")
            Text("·").foregroundStyle(.tertiary)
            Image(systemName: "lock.fill").font(.system(size: 9))
            Text("SSH tunnel")
            if session.sandboxDisabled {
                Text("·").foregroundStyle(.tertiary)
                Label("Sandbox off", systemImage: "exclamationmark.shield")
                    .foregroundStyle(Theme.warning)
                    .help("Chromium is running without its process sandbox — either because it runs as root, or because this server blocks unprivileged user namespaces (common in containers and on Ubuntu 23.10+). Browsing works normally; just avoid untrusted sites, or connect as a non-root user and enable user namespaces for full isolation.")
            }
            Spacer()
            if session.viewportCSS != .zero {
                Text(verbatim: "\(Int(session.viewportCSS.width))×\(Int(session.viewportCSS.height))")
                    .monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
            }
            Text(BrowserQuality(rawValue: qualityRaw)?.title ?? "")
            if !session.browserVersion.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Text(session.browserVersion)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.surface)
    }

    // MARK: - Setup states

    @ViewBuilder
    private var setupState: some View {
        switch session.phase {
        case .idle, .ready:
            setupCard {
                hero(symbol: "globe", title: "Remote Browser",
                     message: "Open a real Chromium browser that runs on \(server.nickname) and control it right here.")
                VStack(alignment: .leading, spacing: 12) {
                    featureRow("network", "Browse from the server",
                               "Every request leaves from \(server.host), with the VPS's own IP and network.")
                    featureRow("server.rack", "Reach private services",
                               "Open localhost ports on the VPS — admin panels, dev servers, dashboards.")
                    featureRow("lock.shield", "Private by design",
                               "Streamed over SSH. The browser is never exposed to the internet.")
                    featureRow("clock.arrow.circlepath", "Picks up where you left off",
                               "Tabs, logins and cookies stay on the VPS between sessions.")
                }
                .padding(.vertical, 4)
                Button {
                    Task { await session.connect() }
                } label: {
                    Label("Launch Browser", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Text("Needs Chromium or Google Chrome on the server — if it's missing you can install it in one click.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

        case .working(let step):
            setupCard {
                ProgressView().controlSize(.large).padding(.bottom, 4)
                Text(step).font(.headline).multilineTextAlignment(.center)
                Text("This usually takes a few seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Cancel") { session.disconnect() }
                    .buttonStyle(.bordered)
            }

        case .notInstalled:
            setupCard {
                hero(symbol: "shippingbox", title: "No browser on \(server.nickname)",
                     message: "Chromium or Google Chrome isn't installed on this server yet.")
                Text("VPS Manager can install it with the server's package manager. It needs passwordless sudo for \(server.user) and roughly 400 MB of disk space; Google Chrome is used on x86-64 Debian/Ubuntu, Chromium elsewhere.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Check Again") { Task { await session.connect() } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button {
                        Task { await session.installBrowser() }
                    } label: {
                        Label("Install Browser", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }

        case .installing:
            setupCard {
                ProgressView().controlSize(.large).padding(.bottom, 4)
                Text("Installing the browser on \(server.host)…").font(.headline)
                Text("Downloading and installing packages. This usually takes one to three minutes — you can keep using other tabs meanwhile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .failed(let message):
            setupCard {
                hero(symbol: "exclamationmark.triangle", title: "Browser unavailable", message: nil, tone: Theme.warning)
                ScrollView {
                    InlineErrorBanner(message: message, copyableFix: session.failureFix)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button("Restart Browser on VPS") { Task { await session.restartRemoteBrowser() } }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    Button {
                        Task { await session.connect() }
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func setupCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                content()
            }
            .padding(28)
            .frame(maxWidth: 460)
            .cardBackground(padding: 0)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .defaultScrollAnchor(.center)
    }

    private func hero(symbol: String, title: String, message: String?, tone: Color = Theme.accent) -> some View {
        VStack(spacing: 10) {
            IconTile(systemImage: symbol, size: 56, tone: tone)
            Text(title).font(.title2.weight(.semibold))
            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func featureRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconTile(systemImage: symbol, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - JavaScript dialogs

    private func dialogSheet(_ dialog: BrowserDialog) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconTile(systemImage: dialog.kind == "beforeunload" ? "rectangle.portrait.and.arrow.right" : "globe", size: 30)
                Text(dialog.kind == "beforeunload" ? "Leave this page?" : (dialog.origin.isEmpty ? "This page says" : "\(dialog.origin) says"))
                    .font(.headline)
            }
            if !dialog.message.isEmpty {
                ScrollView {
                    Text(dialog.message)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }
            if dialog.kind == "prompt" {
                TextField("", text: $promptText)
                    .textFieldStyle(.roundedBorder)
                    .onAppear { promptText = dialog.defaultPrompt }
            }
            HStack {
                Spacer()
                if dialog.kind != "alert" {
                    Button(dialog.kind == "beforeunload" ? "Stay" : "Cancel") {
                        session.respondToDialog(accept: false)
                    }
                    .keyboardShortcut(.cancelAction)
                }
                Button(dialog.kind == "beforeunload" ? "Leave" : "OK") {
                    session.respondToDialog(accept: true, text: dialog.kind == "prompt" ? promptText : nil)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    // MARK: - Helpers

    private func displayAddress(_ url: String) -> String {
        url == "about:blank" ? "" : url
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Thin indeterminate progress line shown under the toolbar while a page loads.
private struct LoadingBar: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent, Theme.accent.opacity(0)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: geo.size.width * 0.4, height: 2.5)
                .offset(x: geo.size.width * phase)
        }
        .frame(height: 2.5)
        .clipped()
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

/// Plain row button that highlights on hover — for list-like popovers.
struct HoverRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent.opacity(configuration.isPressed ? 0.18 : (hovering ? 0.1 : 0)))
                )
                .onHover { hovering = $0 }
        }
    }
}
