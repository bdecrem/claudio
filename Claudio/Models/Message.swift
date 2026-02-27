import Foundation

struct ImageAttachment: Identifiable, Equatable {
    let id = UUID()
    let filename: String
    let contentType: String
    let data: Data
}

struct Message: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date
    var isStreaming: Bool
    var toolCalls: [ToolCall]
    var imageAttachments: [ImageAttachment]

    // Room message identity (nil for 1-on-1 chats)
    var senderId: String?
    var senderDisplayName: String?
    var senderEmoji: String?
    var mentions: [String]?
    var replyToId: String?

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    init(id: UUID = UUID(), role: Role, content: String, timestamp: Date = Date(), isStreaming: Bool = false, toolCalls: [ToolCall] = [], imageAttachments: [ImageAttachment] = [], senderId: String? = nil, senderDisplayName: String? = nil, senderEmoji: String? = nil, mentions: [String]? = nil, replyToId: String? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.toolCalls = toolCalls
        self.imageAttachments = imageAttachments
        self.senderId = senderId
        self.senderDisplayName = senderDisplayName
        self.senderEmoji = senderEmoji
        self.mentions = mentions
        self.replyToId = replyToId
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
        case senderId, senderDisplayName, senderEmoji, mentions, replyToId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isStreaming = false
        toolCalls = []
        imageAttachments = []
        senderId = try container.decodeIfPresent(String.self, forKey: .senderId)
        senderDisplayName = try container.decodeIfPresent(String.self, forKey: .senderDisplayName)
        senderEmoji = try container.decodeIfPresent(String.self, forKey: .senderEmoji)
        mentions = try container.decodeIfPresent([String].self, forKey: .mentions)
        replyToId = try container.decodeIfPresent(String.self, forKey: .replyToId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(senderId, forKey: .senderId)
        try container.encodeIfPresent(senderDisplayName, forKey: .senderDisplayName)
        try container.encodeIfPresent(senderEmoji, forKey: .senderEmoji)
        try container.encodeIfPresent(mentions, forKey: .mentions)
        try container.encodeIfPresent(replyToId, forKey: .replyToId)
    }
}
