import Foundation
import UserNotifications
import AppKit

@MainActor
final class HealthMonitor: NSObject, ObservableObject {
    static let shared = HealthMonitor()

    private var lastPM2Status: [String: String] = [:]      // key: "<serverID>|<processName>"
    private var lastSystemdStatus: [String: String] = [:]   // key: "<serverID>|<unitName>"
    private var lastReachable: [UUID: Bool] = [:]
    private var diskWarned: Set<UUID> = []
    private var memWarned: Set<UUID> = []
    private weak var store: AppStore?
    private var started = false

    /// Sets up notification permissions and tap handling. Polling itself is done
    /// by FleetStatus (one SSH round per server for the whole app), which hands
    /// each result to `ingest`. The first result per item only seeds known state,
    /// so launching doesn't produce a wall of alerts for things already broken —
    /// only transitions from healthy to unhealthy notify.
    func start(store: AppStore) {
        self.store = store
        guard !started else { return }
        started = true
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func ingest(_ snapshot: FleetStatus.Snapshot, server: Server) {
        let h = snapshot.health
        let wasReachable = lastReachable[server.id]
        lastReachable[server.id] = h.reachable
        if wasReachable == true && !h.reachable {
            notify(title: "\(server.nickname) is unreachable",
                   body: "SSH to \(server.host) stopped responding.",
                   serverID: server.id, tab: .overview)
        }
        guard h.reachable else { return }

        for proc in snapshot.pm2 {
            let key = "\(server.id)|\(proc.name)"
            if lastPM2Status[key] == "online" && proc.status != "online" {
                notify(title: "\(proc.name) stopped",
                       body: "PM2 app on \(server.nickname) is now \(proc.status).",
                       serverID: server.id, tab: .pm2)
            }
            lastPM2Status[key] = proc.status
        }

        for unit in snapshot.systemd {
            let key = "\(server.id)|\(unit.name)"
            if lastSystemdStatus[key] == "active" && unit.activeState == "failed" {
                notify(title: "\(unit.name) failed",
                       body: "systemd service on \(server.nickname) has failed.",
                       serverID: server.id, tab: .systemd)
            }
            lastSystemdStatus[key] = unit.activeState
        }

        // Only notify once per crossing, not on every poll while it stays high.
        if h.diskFraction >= 0.9 {
            if diskWarned.insert(server.id).inserted {
                notify(title: "\(server.nickname) low on disk",
                       body: "Disk usage is at \(Int(h.diskFraction * 100))%.",
                       serverID: server.id, tab: .overview)
            }
        } else {
            diskWarned.remove(server.id)
        }

        if h.memTotal > 0 && h.memFraction >= 0.9 {
            if memWarned.insert(server.id).inserted {
                notify(title: "\(server.nickname) low on memory",
                       body: "Only \(Int((1 - h.memFraction) * 100))% memory available.",
                       serverID: server.id, tab: .overview)
            }
        } else {
            memWarned.remove(server.id)
        }
    }

    private func notify(title: String, body: String, serverID: UUID, tab: ServerTab) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["serverID": serverID.uuidString, "tab": tab.rawValue]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func handleNotificationTap(userInfo: [AnyHashable: Any]) {
        guard let store,
              let serverIDStr = userInfo["serverID"] as? String,
              let serverID = UUID(uuidString: serverIDStr) else { return }
        store.pendingServerID = serverID
        if let tabRaw = userInfo["tab"] as? String, let tab = ServerTab(rawValue: tabRaw) {
            store.pendingTab = tab
        }
        NSApp.showInDock()
        WindowOpener.shared.showMain()
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension HealthMonitor: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            self.handleNotificationTap(userInfo: info)
            completionHandler()
        }
    }

    /// Still show the banner even while the app is frontmost, matching normal
    /// expectations for this kind of alert.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}