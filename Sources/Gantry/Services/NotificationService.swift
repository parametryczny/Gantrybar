import AppKit
import UserNotifications

/// Posts native notifications through UNUserNotificationCenter so they belong to Gantry
/// (its own icon, and tapping brings Gantry forward) instead of the AppleScript host that
/// `osascript display notification` runs under.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()

    private var authorizationRequested = false

    private override init() { super.init() }

    /// Registers the delegate and requests permission. Call once at launch.
    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        guard !shared.authorizationRequested else { return }
        shared.authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, subtitle: String? = nil, userInfo: [String: String] = [:]) {
        guard !QuietHours.isActive() else { return }   // suppressed during quiet hours
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound = .default
        if !userInfo.isEmpty { content.userInfo = userInfo }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    // Show banners even when Gantry is the active app.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Bring Gantry forward and open the dashboard when a notification is tapped.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let isUpdate = (response.notification.request.content.userInfo["type"] as? String) == "update"
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: isUpdate ? .gantryCheckForUpdates : .gantryShowDashboard, object: nil)
        }
    }
}

extension Notification.Name {
    static let gantryShowDashboard = Notification.Name("pl.gantry.showDashboard")
    static let gantryCheckForUpdates = Notification.Name("pl.gantry.checkForUpdates")
}
