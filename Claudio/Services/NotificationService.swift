import Foundation
import UserNotifications
#if canImport(UIKit)
import UIKit
#endif
import os

private let log = Logger(subsystem: "com.claudio.app", category: "Notifications")

@Observable
final class NotificationService {
    static let shared = NotificationService()

    enum PermissionState {
        case notDetermined
        case authorized
        case denied
    }

    private(set) var permissionState: PermissionState = .notDetermined
    private(set) var apnsToken: String?

    // User preferences (persisted)
    var notificationsEnabled: Bool {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }
    var notifyAgentMessages: Bool {
        didSet { UserDefaults.standard.set(notifyAgentMessages, forKey: "notifyAgentMessages") }
    }
    var notifyMentions: Bool {
        didSet { UserDefaults.standard.set(notifyMentions, forKey: "notifyMentions") }
    }
    var notifyAllEvents: Bool {
        didSet { UserDefaults.standard.set(notifyAllEvents, forKey: "notifyAllEvents") }
    }

    private init() {
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        self.notifyAgentMessages = UserDefaults.standard.object(forKey: "notifyAgentMessages") as? Bool ?? true
        self.notifyMentions = UserDefaults.standard.object(forKey: "notifyMentions") as? Bool ?? false
        self.notifyAllEvents = UserDefaults.standard.bool(forKey: "notifyAllEvents")
        Task { await refreshPermissionState() }
    }

    // MARK: - Permission

    @MainActor
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            permissionState = granted ? .authorized : .denied
            if granted {
                #if os(iOS)
                UIApplication.shared.registerForRemoteNotifications()
                #endif
                log.info("Push permission granted, registering for remote notifications")
            } else {
                log.info("Push permission denied by user")
            }
        } catch {
            log.error("requestAuthorization failed: \(error)")
            permissionState = .denied
        }
    }

    func refreshPermissionState() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        await MainActor.run {
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                permissionState = .authorized
            case .denied:
                permissionState = .denied
            case .notDetermined:
                permissionState = .notDetermined
            @unknown default:
                permissionState = .notDetermined
            }
        }
    }

    // MARK: - APNs Token

    func setAPNsToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        apnsToken = hex
        log.info("APNs token: \(hex.prefix(8))...")
    }

    func registrationFailed(_ error: Error) {
        log.error("APNs registration failed: \(error)")
    }

    // MARK: - Server Registration

    func registerTokenIfNeeded(via client: WebSocketClient) async {
        guard notificationsEnabled, let token = apnsToken else { return }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.kochito.claudio"
        do {
            _ = try await client.registerApnsToken(token, bundleId: bundleId)
            log.info("APNs token registered with server")
        } catch {
            log.error("Failed to register APNs token: \(error)")
        }
    }
}
