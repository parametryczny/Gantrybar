import AppKit
import UserNotifications

/// Posts native notifications through UNUserNotificationCenter so they belong to Gantry
/// (its own icon, and tapping brings Gantry forward) instead of the AppleScript host that
/// `osascript display notification` runs under.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationService()

    private var authorizationRequested = false

    private override init() { super.init() }

    /// A warning about a print failure carries two buttons, because only the person who looks at the
    /// printer knows whether the guess was right, and their answer is worth more than the guess.
    static let defectCategory = "pl.gantry.defect"
    static let confirmAction = "pl.gantry.defect.confirm"
    static let rejectAction = "pl.gantry.defect.reject"

    /// Registers the delegate and requests permission. Call once at launch, from the main actor:
    /// the button titles come from the language catalogue, which lives there.
    @MainActor
    static func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = shared
        let confirm = UNNotificationAction(identifier: confirmAction,
                                           title: AppSettings.shared.t("Yes, it failed"), options: [])
        let reject = UNNotificationAction(identifier: rejectAction,
                                          title: AppSettings.shared.t("False alarm"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: defectCategory, actions: [confirm, reject],
                                   intentIdentifiers: [], options: [])
        ])
        guard !shared.authorizationRequested else { return }
        shared.authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String, subtitle: String? = nil,
                     userInfo: [String: String] = [:], category: String? = nil) {
        guard !QuietHours.isActive() else { return }   // suppressed during quiet hours
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.sound = .default
        if let category { content.categoryIdentifier = category }
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
        let info = response.notification.request.content.userInfo
        // The answer to a failure warning: the frame that caused it is filed under what the user says
        // it was, right or wrong, and the prototypes are rebuilt so the next look already knows better.
        if let frame = info["frame"] as? String,
           response.actionIdentifier == Self.confirmAction || response.actionIdentifier == Self.rejectAction {
            let confirmed = response.actionIdentifier == Self.confirmAction
            await MainActor.run {
                DefectDataset.refile(frame: URL(fileURLWithPath: frame),
                                     as: confirmed ? nil : .ok)
                DefectWatch.current?.rebuildPrototypes()
            }
            return
        }
        let isUpdate = (info["type"] as? String) == "update"
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
