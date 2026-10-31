import Foundation
import UserNotifications
import UIKit

// In-app banners for bridge events, Allow/Deny actions on approvals, and routing taps to the session.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    weak var client: BridgeClient?

    private static let approvalCategory = "APPROVAL"

    func setup(client: BridgeClient) {
        self.client = client
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let allow = UNNotificationAction(identifier: "ALLOW", title: "Allow", options: [], icon: UNNotificationActionIcon(systemImageName: "checkmark"))
        let deny = UNNotificationAction(identifier: "DENY", title: "Deny", options: [.destructive], icon: UNNotificationActionIcon(systemImageName: "xmark"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory, actions: [allow, deny], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // Shown while the app is open (willPresent turns it into a banner). When the app is closed,
    // the bridge pushes the same event through ntfy instead, so there are no duplicates.
    func banner(_ title: String, subtitle: String, body: String, sessionId: String, approvalId: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = sessionId
        content.userInfo = ["sessionId": sessionId, "requestId": approvalId ?? ""]
        if approvalId != nil {
            content.categoryIdentifier = Self.approvalCategory
            content.interruptionLevel = .timeSensitive
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: approvalId ?? UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let sessionId = info["sessionId"] as? String
        let requestId = info["requestId"] as? String ?? ""
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case "ALLOW" where !requestId.isEmpty: self.client?.decide(requestId: requestId, allow: true)
            case "DENY" where !requestId.isEmpty: self.client?.decide(requestId: requestId, allow: false)
            default: if let sessionId { self.client?.openSessionId = sessionId }
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
