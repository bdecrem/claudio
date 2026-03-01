import XCTest
@testable import Claudio

final class NotificationServiceTests: XCTestCase {

    private let testKeys = [
        "notificationsEnabled",
        "notifyAgentMessages",
        "notifyMentions",
        "notifyAllEvents",
        "hasPromptedForNotifications"
    ]

    override func setUp() {
        super.setUp()
        testKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        testKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - APNs Token Hex Conversion

    func testAPNsTokenHexConversion() {
        let service = NotificationService(testDefaults: .standard)
        let tokenBytes: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x23, 0x45, 0x67]
        let tokenData = Data(tokenBytes)

        service.setAPNsToken(tokenData)

        XCTAssertEqual(service.apnsToken, "deadbeef01234567")
    }

    func testAPNsTokenEmptyData() {
        let service = NotificationService(testDefaults: .standard)
        service.setAPNsToken(Data())
        XCTAssertEqual(service.apnsToken, "")
    }

    // MARK: - Preference Defaults

    func testNotificationsEnabledDefaultsFalse() {
        let service = NotificationService(testDefaults: .standard)
        XCTAssertFalse(service.notificationsEnabled)
    }

    func testNotifyAgentMessagesDefaultsTrue() {
        let service = NotificationService(testDefaults: .standard)
        XCTAssertTrue(service.notifyAgentMessages)
    }

    func testNotifyMentionsDefaultsFalse() {
        let service = NotificationService(testDefaults: .standard)
        XCTAssertFalse(service.notifyMentions)
    }

    func testNotifyAllEventsDefaultsFalse() {
        let service = NotificationService(testDefaults: .standard)
        XCTAssertFalse(service.notifyAllEvents)
    }

    func testHasPromptedDefaultsFalse() {
        let service = NotificationService(testDefaults: .standard)
        XCTAssertFalse(service.hasPromptedForNotifications)
    }

    // MARK: - Preference Persistence

    func testNotificationsEnabledPersists() {
        let service = NotificationService(testDefaults: .standard)
        service.notificationsEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "notificationsEnabled"))
    }

    func testNotifyAgentMessagesPersists() {
        let service = NotificationService(testDefaults: .standard)
        service.notifyAgentMessages = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "notifyAgentMessages"))
    }

    func testHasPromptedPersists() {
        let service = NotificationService(testDefaults: .standard)
        service.hasPromptedForNotifications = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "hasPromptedForNotifications"))
    }

    func testPreferencesRestoreFromDefaults() {
        UserDefaults.standard.set(true, forKey: "notificationsEnabled")
        UserDefaults.standard.set(false, forKey: "notifyAgentMessages")
        UserDefaults.standard.set(true, forKey: "notifyMentions")
        UserDefaults.standard.set(true, forKey: "hasPromptedForNotifications")

        let service = NotificationService(testDefaults: .standard)

        XCTAssertTrue(service.notificationsEnabled)
        XCTAssertFalse(service.notifyAgentMessages)
        XCTAssertTrue(service.notifyMentions)
        XCTAssertTrue(service.hasPromptedForNotifications)
    }

    // MARK: - Pending Agent ID

    func testPendingAgentIdStartsNil() {
        let service = NotificationService(testDefaults: .standard)
        XCTAssertNil(service.pendingAgentId)
    }

    func testPendingAgentIdCanBeSet() {
        let service = NotificationService(testDefaults: .standard)
        service.pendingAgentId = "mave"
        XCTAssertEqual(service.pendingAgentId, "mave")
    }

    func testPendingAgentIdCanBeCleared() {
        let service = NotificationService(testDefaults: .standard)
        service.pendingAgentId = "mave"
        service.pendingAgentId = nil
        XCTAssertNil(service.pendingAgentId)
    }
}
