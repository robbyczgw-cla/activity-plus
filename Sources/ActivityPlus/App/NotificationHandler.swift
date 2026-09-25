import ActivityCore
import AppKit
import UserNotifications

/// Notifications with buttons: automations that ask first, and opening the right page on click.
final class NotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationHandler()
    private static let automationCategory = "automation"

    func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let run = UNNotificationAction(identifier: "run", title: "Do it", options: [])
        let skip = UNNotificationAction(identifier: "skip", title: "Not now", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.automationCategory, actions: [run, skip], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor func askAboutAutomation(_ match: AutomationMatch) {
        let content = UNMutableNotificationContent()
        content.title = match.rule.summary
        content.body = match.reason
        content.categoryIdentifier = Self.automationCategory
        content.userInfo = ["match": match.id]
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "automation-\(match.id)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let matchID = response.notification.request.content.userInfo["match"] as? String
        let action = response.actionIdentifier
        await MainActor.run {
            if let matchID {
                switch action {
                case "run": AppServices.shared.approve(matchID)
                case "skip": AppServices.shared.dismiss(matchID)
                default: WindowOpener.openMain(page: "automations")
                }
            } else {
                WindowOpener.openMain(page: "alerts")
            }
        }
    }

    /// Show notifications even while Activity+ is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }
}
