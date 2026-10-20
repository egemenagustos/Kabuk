import Foundation
import KabukCore
import UserNotifications

/// Posts macOS notifications and routes clicks back to the session that sent them.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpenSession: ((UUID) -> Void)?
    var onPermissionAnswer: ((String, PermissionDecision) -> Void)?
    /// Drops every notification; the recorded demo runs muted.
    var muted = false

    private static let permissionCategory = "PERMISSION"

    /// UNUserNotificationCenter needs a bundled app; `swift run` builds have no bundle id.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        let allow = UNNotificationAction(identifier: PermissionDecision.allow.rawValue, title: "Allow")
        let deny = UNNotificationAction(identifier: PermissionDecision.deny.rawValue, title: "Deny", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.permissionCategory, actions: [allow, deny], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String, sessionID: UUID, permissionRequest: String? = nil) {
        guard !muted, let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["session": sessionID.uuidString, "request": permissionRequest ?? ""]
        if permissionRequest != nil { content.categoryIdentifier = Self.permissionCategory }
        content.threadIdentifier = sessionID.uuidString
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["session"] as? String).flatMap(UUID.init)
        let request = info["request"] as? String ?? ""
        let decision = PermissionDecision(rawValue: response.actionIdentifier)
        DispatchQueue.main.async { [weak self] in
            if let decision, !request.isEmpty {
                self?.onPermissionAnswer?(request, decision)
            } else if let id {
                self?.onOpenSession?(id)
            }
            completionHandler()
        }
    }
}
