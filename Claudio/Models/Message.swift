import Foundation

struct Message: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var toolCalls: [ToolCall]

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date(), isStreaming: Bool = false, toolCalls: [ToolCall] = []) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
    }

    var apiRepresentation: [String: String] {
        ["role": role.rawValue, "content": content]
    }
}

// MARK: - Tool Call

struct ToolCall: Identifiable, Equatable {
    let id: String          // callId from server
    let name: String        // tool name (e.g. "exec")
    let args: [String: String]
    var output: String?     // nil until tool_result arrives
    var isComplete: Bool { output != nil }
}

// MARK: - Codable (isStreaming excluded — never restores as streaming)

extension Message: Codable {
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isStreaming = false
        toolCalls = []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
    }
}
