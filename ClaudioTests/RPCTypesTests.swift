import XCTest
@testable import Claudio

final class RPCTypesTests: XCTestCase {

    // MARK: - AnyCodableValue

    func testStringValue() {
        let val = AnyCodableValue.string("hello")
        XCTAssertEqual(val.stringValue, "hello")
        XCTAssertNil(val.intValue)
        XCTAssertNil(val.boolValue)
    }

    func testIntValue() {
        let val = AnyCodableValue.int(42)
        XCTAssertEqual(val.intValue, 42)
        XCTAssertEqual(val.doubleValue, 42.0) // int → double coercion
        XCTAssertNil(val.stringValue)
    }

    func testDoubleToInt() {
        let val = AnyCodableValue.double(3.14)
        XCTAssertEqual(val.doubleValue, 3.14)
        XCTAssertEqual(val.intValue, 3) // double → int truncation
    }

    func testBoolValue() {
        XCTAssertEqual(AnyCodableValue.bool(true).boolValue, true)
        XCTAssertNil(AnyCodableValue.string("true").boolValue)
    }

    func testNullReturnsNilEverywhere() {
        let val = AnyCodableValue.null
        XCTAssertNil(val.stringValue)
        XCTAssertNil(val.intValue)
        XCTAssertNil(val.doubleValue)
        XCTAssertNil(val.boolValue)
        XCTAssertNil(val.objectValue)
        XCTAssertNil(val.arrayValue)
    }

    func testJSONRoundTrip() throws {
        let original: [String: AnyCodableValue] = [
            "name": .string("test"),
            "count": .int(5),
            "active": .bool(true),
            "tags": .array([.string("a"), .string("b")]),
            "meta": .null
        ]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - ChatEvent

    func testChatEventDelta() {
        let payload: [String: AnyCodableValue] = [
            "sessionKey": .string("sess1"),
            "runId": .string("run1"),
            "state": .string("delta"),
            "message": .object([
                "content": .array([
                    .object(["type": .string("text"), "text": .string("Hello world")])
                ])
            ])
        ]
        let event = ChatEvent(from: payload)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.state, .delta)
        XCTAssertEqual(event?.text, "Hello world")
        XCTAssertEqual(event?.sessionKey, "sess1")
    }

    func testChatEventFinal() {
        let payload: [String: AnyCodableValue] = [
            "sessionKey": .string("s"),
            "runId": .string("r"),
            "state": .string("final"),
        ]
        let event = ChatEvent(from: payload)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.state, .final_)
        XCTAssertNil(event?.text)
    }

    func testChatEventRejectsInvalidState() {
        let payload: [String: AnyCodableValue] = [
            "state": .string("garbage"),
        ]
        XCTAssertNil(ChatEvent(from: payload))
    }

    func testChatEventRejectsNil() {
        XCTAssertNil(ChatEvent(from: nil))
    }

    // MARK: - AgentEvent

    func testAgentEventWithArgs() {
        let payload: [String: AnyCodableValue] = [
            "sessionKey": .string("s"),
            "runId": .string("r"),
            "stream": .string("tool"),
            "data": .object([
                "phase": .string("start"),
                "toolCallId": .string("tc1"),
                "name": .string("exec"),
                "args": .object([
                    "command": .string("ls -la"),
                    "timeout": .int(30),
                    "verbose": .bool(true),
                    "ratio": .double(0.5),
                ]),
            ])
        ]
        let event = AgentEvent(from: payload)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.stream, "tool")
        XCTAssertEqual(event?.phase, "start")
        XCTAssertEqual(event?.toolName, "exec")
        XCTAssertEqual(event?.args?["command"], "ls -la")
        XCTAssertEqual(event?.args?["timeout"], "30")
        XCTAssertEqual(event?.args?["verbose"], "true")
        XCTAssertEqual(event?.args?["ratio"], "0.5")
    }

    func testAgentEventRejectsMissingStream() {
        let payload: [String: AnyCodableValue] = [
            "data": .object(["phase": .string("start")])
        ]
        XCTAssertNil(AgentEvent(from: payload))
    }

    // MARK: - HistoryMessage

    func testHistoryMessagePlainString() {
        let value = AnyCodableValue.object([
            "role": .string("user"),
            "content": .string("Hello"),
            "timestamp": .double(1700000000000),
        ])
        let msg = HistoryMessage(from: value)
        XCTAssertNotNil(msg)
        XCTAssertEqual(msg?.role, "user")
        XCTAssertEqual(msg?.content, "Hello")
        XCTAssertNotNil(msg?.timestamp)
    }

    func testHistoryMessageContentBlocks() {
        let value = AnyCodableValue.object([
            "role": .string("assistant"),
            "content": .array([
                .object(["type": .string("text"), "text": .string("Part 1")]),
                .object(["type": .string("text"), "text": .string(" Part 2")]),
            ])
        ])
        let msg = HistoryMessage(from: value)
        XCTAssertEqual(msg?.content, "Part 1 Part 2")
    }

    func testHistoryMessageSkipsEmptyContent() {
        let value = AnyCodableValue.object([
            "role": .string("assistant"),
            "content": .array([
                .object(["type": .string("thinking"), "thinking": .string("hmm")]),
            ])
        ])
        XCTAssertNil(HistoryMessage(from: value))
    }

    // MARK: - WSAgent

    func testWSAgentParsing() {
        let value = AnyCodableValue.object([
            "id": .string("mave"),
            "name": .string("Mave"),
            "emoji": .string("🌊"),
            "color": .string("#00CCCC"),
        ])
        let agent = WSAgent(from: value)
        XCTAssertNotNil(agent)
        XCTAssertEqual(agent?.id, "mave")
        XCTAssertEqual(agent?.name, "Mave")
        XCTAssertEqual(agent?.emoji, "🌊")
    }

    func testWSAgentFallsBackToIdForName() {
        let value = AnyCodableValue.object([
            "id": .string("test"),
        ])
        let agent = WSAgent(from: value)
        XCTAssertEqual(agent?.name, "test")
        XCTAssertNil(agent?.emoji)
    }

    func testWSAgentRejectsMissingId() {
        let value = AnyCodableValue.object([
            "name": .string("No ID"),
        ])
        XCTAssertNil(WSAgent(from: value))
    }
}
