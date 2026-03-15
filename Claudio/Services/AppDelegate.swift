#if os(iOS)
import UIKit
import UserNotifications
import os

private let log = Logger(subsystem: "com.claudio.app", category: "AppDelegate")

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    // MARK: - APNs Token

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationService.shared.setAPNsToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationService.shared.registrationFailed(error)
    }

    // MARK: - Foreground Notifications

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if let agentId = userInfo["agentId"] as? String,
           agentId == currentlySelectedAgentId {
            // Don't show banner for the chat the user is already looking at
            return []
        }
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        log.info("Notification tapped: \(response.notification.request.identifier)")
        if let agentId = userInfo["agentId"] as? String {
            log.info("Routing to agent: \(agentId)")
            await MainActor.run {
                NotificationService.shared.pendingAgentId = agentId
            }
        }
    }

    /// The raw agentId of the currently selected agent (set by ChatService via ClaudioApp).
    var currentlySelectedAgentId: String?
}

#elseif os(macOS)
import AppKit
import UserNotifications
import os

private let log = Logger(subsystem: "com.claudio.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - APNs Token

    func application(
        _ application: NSApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationService.shared.setAPNsToken(deviceToken)
    }

    func application(
        _ application: NSApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationService.shared.registrationFailed(error)
    }

    // MARK: - Foreground Notifications

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if let agentId = userInfo["agentId"] as? String,
           agentId == currentlySelectedAgentId {
            return []
        }
        return [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        log.info("Notification tapped: \(response.notification.request.identifier)")
        if let agentId = userInfo["agentId"] as? String {
            log.info("Routing to agent: \(agentId)")
            await MainActor.run {
                NotificationService.shared.pendingAgentId = agentId
            }
        }
    }

    var currentlySelectedAgentId: String?
}
#endif
