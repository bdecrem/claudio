import XCTest
@testable import Claudio

final class ChatServiceTests: XCTestCase {

    private var service: ChatService!

    override func setUp() {
        super.setUp()
        // Clear relevant UserDefaults keys before each test
        let keys = ["selectedAgent", "activeServerIndex", "hiddenAgentIds", "savedServers", "chatState"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        service = ChatService()
    }

    override func tearDown() {
        let keys = ["selectedAgent", "activeServerIndex", "hiddenAgentIds", "savedServers", "chatState"]
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        service = nil
        super.tearDown()
    }

    // MARK: - Message Codable Round-Trip

    func testMessageRoundTrip() throws {
        let original = Message(role: .user, content: "Hello world")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.role, .user)
        XCTAssertEqual(decoded.content, "Hello world")
        XCTAssertFalse(decoded.isStreaming, "isStreaming should always decode as false")
        XCTAssertTrue(decoded.toolCalls.isEmpty, "toolCalls should not persist")
        XCTAssertTrue(decoded.imageAttachments.isEmpty, "imageAttachments should not persist")
    }

    func testStreamingMessageDecodesAsNotStreaming() throws {
        let streaming = Message(role: .assistant, content: "partial...", isStreaming: true)
        let data = try JSONEncoder().encode(streaming)
        let decoded = try JSONDecoder().decode(Message.self, from: data)

        XCTAssertFalse(decoded.isStreaming, "Restored messages should never be streaming")
    }

    func testMessageArrayRoundTrip() throws {
        let messages = [
            Message(role: .user, content: "Hi"),
            Message(role: .assistant, content: "Hello!"),
            Message(role: .user, content: "How are you?"),
        ]
        let data = try JSONEncoder().encode(messages)
        let decoded = try JSONDecoder().decode([Message].self, from: data)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].content, "Hi")
        XCTAssertEqual(decoded[1].role, .assistant)
        XCTAssertEqual(decoded[2].content, "How are you?")
    }

    // MARK: - API Representation

    func testApiRepresentation() {
        let msg = Message(role: .assistant, content: "test response")
        let api = msg.apiRepresentation
        XCTAssertEqual(api["role"], "assistant")
        XCTAssertEqual(api["content"], "test response")
    }

    // MARK: - Agent Switching & History

    func testAgentSwitchingPreservesHistory() {
        // Simulate having agents loaded
        service.agents = [
            ChatService.Agent(id: "0:alpha", agentId: "alpha", name: "Alpha", emoji: nil, color: nil, serverIndex: 0),
            ChatService.Agent(id: "0:beta", agentId: "beta", name: "Beta", emoji: nil, color: nil, serverIndex: 0),
        ]

        // Select first agent and add messages
        service.selectedAgent = "0:alpha"
        service.messages = [
            Message(role: .user, content: "Hello Alpha"),
            Message(role: .assistant, content: "Hi from Alpha"),
        ]

        // Switch to second agent
        service.selectedAgent = "0:beta"
        XCTAssertTrue(service.messages.isEmpty, "New agent should start with empty messages")

        // Add messages to second agent
        service.messages = [
            Message(role: .user, content: "Hello Beta"),
        ]

        // Switch back to first agent
        service.selectedAgent = "0:alpha"
        XCTAssertEqual(service.messages.count, 2, "Alpha's history should be restored")
        XCTAssertEqual(service.messages[0].content, "Hello Alpha")
        XCTAssertEqual(service.messages[1].content, "Hi from Alpha")

        // Switch back to second agent
        service.selectedAgent = "0:beta"
        XCTAssertEqual(service.messages.count, 1, "Beta's history should be restored")
        XCTAssertEqual(service.messages[0].content, "Hello Beta")
    }

    func testSwitchingToSameAgentIsNoOp() {
        service.selectedAgent = "0:test"
        service.messages = [Message(role: .user, content: "Keep me")]

        // Setting to same value should not clear messages
        service.selectedAgent = "0:test"
        XCTAssertEqual(service.messages.count, 1)
        XCTAssertEqual(service.messages[0].content, "Keep me")
    }

    // MARK: - Agent Visibility

    func testToggleAgentVisibility() {
        service.agents = [
            ChatService.Agent(id: "0:a", agentId: "a", name: "A", emoji: nil, color: nil, serverIndex: 0),
            ChatService.Agent(id: "0:b", agentId: "b", name: "B", emoji: nil, color: nil, serverIndex: 0),
        ]

        XCTAssertEqual(service.visibleAgents.count, 2)

        service.toggleAgentVisibility("0:a")
        XCTAssertEqual(service.visibleAgents.count, 1)
        XCTAssertEqual(service.visibleAgents[0].id, "0:b")

        // Toggle back
        service.toggleAgentVisibility("0:a")
        XCTAssertEqual(service.visibleAgents.count, 2)
    }

    func testCannotHideLastVisibleAgent() {
        service.agents = [
            ChatService.Agent(id: "0:only", agentId: "only", name: "Only", emoji: nil, color: nil, serverIndex: 0),
        ]

        service.toggleAgentVisibility("0:only")
        XCTAssertEqual(service.visibleAgents.count, 1, "Should not hide the last visible agent")
    }

    func testHidingSelectedAgentSwitchesToFirstVisible() {
        service.agents = [
            ChatService.Agent(id: "0:a", agentId: "a", name: "A", emoji: nil, color: nil, serverIndex: 0),
            ChatService.Agent(id: "0:b", agentId: "b", name: "B", emoji: nil, color: nil, serverIndex: 0),
        ]
        service.selectedAgent = "0:a"

        service.toggleAgentVisibility("0:a")
        XCTAssertEqual(service.selectedAgent, "0:b", "Should auto-switch to first visible agent")
    }

    // MARK: - Clear Messages

    func testClearMessages() {
        service.selectedAgent = "0:test"
        service.messages = [
            Message(role: .user, content: "Hello"),
            Message(role: .assistant, content: "Hi"),
        ]
        service.connectionError = "some error"

        service.clearMessages()
        XCTAssertTrue(service.messages.isEmpty)
        XCTAssertNil(service.connectionError)
    }

    // MARK: - Chat State Persistence

    func testChatPersistenceRoundTrip() {
        service.selectedAgent = "0:test"
        service.messages = [
            Message(role: .user, content: "Persisted message"),
            Message(role: .assistant, content: "Persisted reply"),
        ]
        service.persistChatHistories()

        // Create a new service instance — should restore
        let restored = ChatService()
        // It restores based on selectedAgent in UserDefaults
        XCTAssertEqual(restored.messages.count, 2)
        XCTAssertEqual(restored.messages[0].content, "Persisted message")
        XCTAssertEqual(restored.messages[1].content, "Persisted reply")
    }

    func testStaleChatStateIsDiscarded() {
        // Manually write a chat state with an old timestamp
        struct FakeChatState: Codable {
            let histories: [String: [Message]]
            let savedAt: Date
        }

        let oldState = FakeChatState(
            histories: ["0:test": [Message(role: .user, content: "Old")]],
            savedAt: Date().addingTimeInterval(-25 * 60 * 60) // 25 hours ago
        )
        if let data = try? JSONEncoder().encode(oldState) {
            UserDefaults.standard.set(data, forKey: "chatState")
        }
        UserDefaults.standard.set("0:test", forKey: "selectedAgent")

        let restored = ChatService()
        XCTAssertTrue(restored.messages.isEmpty, "Messages older than 24h should be discarded")
    }

    // MARK: - Server Management

    func testInitialStateHasNoServer() {
        XCTAssertFalse(service.hasServer)
        XCTAssertNil(service.activeServer)
        XCTAssertTrue(service.savedServers.isEmpty)
    }

    // MARK: - ToolCall

    func testToolCallIsComplete() {
        let incomplete = ToolCall(id: "1", name: "exec", args: ["cmd": "ls"])
        XCTAssertFalse(incomplete.isComplete)

        var complete = ToolCall(id: "2", name: "exec", args: [:])
        complete.output = "done"
        XCTAssertTrue(complete.isComplete)
    }
}
