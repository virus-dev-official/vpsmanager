import SwiftUI

struct QuickSwitchItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String
    let serverID: UUID
    let tab: ServerTab
}

struct QuickSwitcherView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    var onSelect: (UUID, ServerTab) -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    private var allItems: [QuickSwitchItem] {
        var results: [QuickSwitchItem] = []
        for server in store.servers {
            results.append(QuickSwitchItem(icon: "server.rack", title: server.nickname, subtitle: server.sshTarget, serverID: server.id, tab: .overview))
            for tab in ServerTab.allCases where tab != .overview {
                results.append(QuickSwitchItem(icon: tab.icon, title: tab.rawValue, subtitle: server.nickname, serverID: server.id, tab: tab))
            }
            for project in store.projects(for: server.id) {
                results.append(QuickSwitchItem(icon: "folder.badge.gearshape", title: project.name, subtitle: "Project on \(server.nickname)", serverID: server.id, tab: .projects))
            }
            for config in store.pm2Configs(for: server.id) {
                results.append(QuickSwitchItem(icon: "bolt.horizontal.circle", title: config.name, subtitle: "PM2 app on \(server.nickname)", serverID: server.id, tab: .pm2))
            }
            for tunnel in store.tunnels(for: server.id) {
                results.append(QuickSwitchItem(icon: "cloud", title: tunnel.tunnelName, subtitle: "Tunnel on \(server.nickname)", serverID: server.id, tab: .cloudflared))
            }
        }
        return results
    }

    /// Every whitespace-separated word must match the title or subtitle, so
    /// "prod term" finds the Terminal of a server called "prod".
    private var filtered: [QuickSwitchItem] {
        let words = query.split(separator: " ").map(String.init)
        guard !words.isEmpty else {
            // Without a query, list servers plus their most-used sections only.
            return allItems.filter { [.overview, .terminal, .files].contains($0.tab) && $0.icon != "folder.badge.gearshape" }
        }
        return allItems.filter { item in
            words.allSatisfy { item.title.localizedCaseInsensitiveContains($0) || item.subtitle.localizedCaseInsensitiveContains($0) }
        }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                TextField("Jump to a server, section, project, or app…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { choose(items) }
                    .onKeyPress(.downArrow) {
                        highlighted = min(highlighted + 1, max(items.count - 1, 0))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        highlighted = max(highlighted - 1, 0)
                        return .handled
                    }
                Text("esc")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.stroke))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Rectangle().fill(Theme.stroke).frame(height: 1)

            if items.isEmpty {
                ContentUnavailableView(store.servers.isEmpty ? "No Servers Yet" : "No Matches", systemImage: "magnifyingglass")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                row(item, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture { onSelect(item.serverID, item.tab); dismiss() }
                                    .onHover { if $0 { highlighted = index } }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: highlighted) { _, index in
                        proxy.scrollTo(index)
                    }
                }
            }

            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 14) {
                hint("↑↓", "navigate")
                hint("↩", "open")
                Spacer()
                Text("\(items.count) result\(items.count == 1 ? "" : "s")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Theme.surfaceAlt)
        }
        .frame(width: 560, height: 440)
        .background(Theme.surface)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onExitCommand { dismiss() }
    }

    private func choose(_ items: [QuickSwitchItem]) {
        guard items.indices.contains(highlighted) else { return }
        let item = items[highlighted]
        onSelect(item.serverID, item.tab)
        dismiss()
    }

    private func row(_ item: QuickSwitchItem, isHighlighted: Bool) -> some View {
        HStack(spacing: 12) {
            IconTile(systemImage: item.icon, size: 28, tone: isHighlighted ? .white : Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
            }
            Spacer()
            if isHighlighted {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(isHighlighted ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isHighlighted ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.stroke))
            Text(label)
        }
    }
}
