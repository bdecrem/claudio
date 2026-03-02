import Foundation
import UserNotifications
import UIKit
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

    /// Set by AppDelegate when a notification is tapped; observed by ClaudioApp to navigate.
    var pendingAgentId: String?

    /// Whether the user has already been prompted for notifications (post-first-message).
    var hasPromptedForNotifications: Bool {
        didSet { UserDefaults.standard.set(hasPromptedForNotifications, forKey: "hasPromptedForNotifications") }
    }

    private init() {
        self.notificationsEnabled = UserDefaults.standard.bool(forKey: "notificationsEnabled")
        self.notifyAgentMessages = UserDefaults.standard.object(forKey: "notifyAgentMessages") as? Bool ?? true
        self.notifyMentions = UserDefaults.standard.object(forKey: "notifyMentions") as? Bool ?? false
        self.notifyAllEvents = UserDefaults.standard.bool(forKey: "notifyAllEvents")
        self.hasPromptedForNotifications = UserDefaults.standard.bool(forKey: "hasPromptedForNotifications")
        Task { await refreshPermissionState() }
    }

    // Testable initializer — skips singleton and permission refresh
    init(testDefaults: UserDefaults) {
        self.notificationsEnabled = testDefaults.bool(forKey: "notificationsEnabled")
        self.notifyAgentMessages = testDefaults.object(forKey: "notifyAgentMessages") as? Bool ?? true
        self.notifyMentions = testDefaults.object(forKey: "notifyMentions") as? Bool ?? false
        self.notifyAllEvents = testDefaults.bool(forKey: "notifyAllEvents")
        self.hasPromptedForNotifications = testDefaults.bool(forKey: "hasPromptedForNotifications")
    }

    // MARK: - Permission

    @MainActor
    func requestPermission() async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            permissionState = granted ? .authorized : .denied
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
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

    // MARK: - Badge Management

    func updateBadgeCount(_ count: Int) {
        let center = UNUserNotificationCenter.current()
        Task {
            do {
                try await center.setBadgeCount(count)
            } catch {
                log.error("setBadgeCount failed: \(error)")
            }
        }
    }

    func clearBadge() {
        updateBadgeCount(0)
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

    // MARK: - Push Relay Registration

    private static let relayURL = "https://claudio-server-production.up.railway.app"

    /// Registers the APNs token with the central push relay so it can send
    /// notifications on behalf of any OpenClaw server.
    /// When openclawURL and openclawToken are provided, the relay also starts
    /// a persistent WebSocket connection to listen for agent messages.
    func registerTokenWithRelay(deviceId: String, openclawURL: String? = nil, openclawToken: String? = nil) async {
        guard let token = apnsToken, !token.isEmpty else {
            log.info("No APNs token available, skipping relay registration")
            return
        }

        let bundleId = Bundle.main.bundleIdentifier ?? "com.kochito.claudio"
        let url = URL(string: "\(Self.relayURL)/push/register")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body: [String: String] = [
            "deviceId": deviceId,
            "token": token,
            "bundleId": bundleId
        ]

        if let openclawURL, !openclawURL.isEmpty {
            body["openclawURL"] = openclawURL
        }
        if let openclawToken, !openclawToken.isEmpty {
            body["openclawToken"] = openclawToken
        }

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                log.info("APNs token registered with push relay (relay=\(openclawURL != nil))")
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                log.error("Push relay registration failed with status \(status)")
            }
        } catch {
            log.error("Push relay registration failed: \(error)")
        }
    }
}
