import Foundation

struct Room: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var emoji: String?
    var participants: [RoomParticipant]
    var lastMessage: RoomLastMessage?
    var unreadCount: Int
    var participantCount: Int

    init(id: String, name: String, emoji: String? = nil, participants: [RoomParticipant] = [], lastMessage: RoomLastMessage? = nil, unreadCount: Int = 0, participantCount: Int = 0) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.participants = participants
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
        self.participantCount = participantCount
    }

    /// Parse from AnyCodableValue (WebSocket RPC payload)
    init?(from value: AnyCodableValue) {
        guard let obj = value.objectValue,
              let id = obj["id"]?.stringValue,
              let name = obj["name"]?.stringValue else { return nil }

        self.id = id
        self.name = name
        self.emoji = obj["emoji"]?.stringValue
        self.participantCount = obj["participantCount"]?.intValue ?? 0
        self.unreadCount = obj["unreadCount"]?.intValue ?? 0

        if let participantsArr = obj["participants"]?.arrayValue {
            self.participants = participantsArr.compactMap { RoomParticipant(from: $0) }
        } else {
            self.participants = []
        }

        if let lm = obj["lastMessage"]?.objectValue {
            self.lastMessage = RoomLastMessage(
                content: lm["content"]?.stringValue ?? "",
                senderName: lm["senderName"]?.stringValue ?? "",
                senderEmoji: lm["senderEmoji"]?.stringValue ?? "",
                createdAt: lm["createdAt"]?.stringValue ?? ""
            )
        } else {
            self.lastMessage = nil
        }
    }
}

struct RoomParticipant: Identifiable, Equatable, Codable {
    var id: String
    var displayName: String
    var emoji: String?
    var isAgent: Bool
    var isOnline: Bool
    var role: String  // "owner", "admin", "member"

    init(id: String, displayName: String, emoji: String? = nil, isAgent: Bool = false, isOnline: Bool = false, role: String = "member") {
        self.id = id
        self.displayName = displayName
        self.emoji = emoji
        self.isAgent = isAgent
        self.isOnline = isOnline
        self.role = role
    }

    init?(from value: AnyCodableValue) {
        guard let obj = value.objectValue,
              let id = obj["id"]?.stringValue else { return nil }

        self.id = id
        self.displayName = obj["displayName"]?.stringValue ?? id
        self.emoji = obj["emoji"]?.stringValue
        self.isAgent = obj["isAgent"]?.boolValue ?? false
        self.isOnline = obj["isOnline"]?.boolValue ?? false
        self.role = obj["role"]?.stringValue ?? "member"
    }
}

struct RoomLastMessage: Equatable, Codable {
    var content: String
    var senderName: String
    var senderEmoji: String
    var createdAt: String
}

// MARK: - Room Message (parsed from room.message events)

struct RoomMessage {
    let id: String
    let roomId: String
    let senderUserId: String?
    let senderAgentId: String?
    let senderDisplayName: String
    let senderEmoji: String
    let content: String
    let mentions: [String]
    let replyTo: String?
    let createdAt: Date

    init?(from payload: [String: AnyCodableValue]?) {
        guard let payload,
              let roomId = payload["roomId"]?.stringValue,
              let msgObj = payload["message"]?.objectValue,
              let id = msgObj["id"]?.stringValue else { return nil }

        self.id = id
        self.roomId = roomId
        self.senderUserId = msgObj["senderUserId"]?.stringValue
        self.senderAgentId = msgObj["senderAgentId"]?.stringValue
        self.senderDisplayName = msgObj["senderDisplayName"]?.stringValue ?? ""
        self.senderEmoji = msgObj["senderEmoji"]?.stringValue ?? ""
        self.content = msgObj["content"]?.stringValue ?? ""
        self.replyTo = msgObj["replyTo"]?.stringValue

        if let mentionsArr = msgObj["mentions"]?.arrayValue {
            self.mentions = mentionsArr.compactMap { $0.stringValue }
        } else {
            self.mentions = []
        }

        if let ts = msgObj["createdAt"]?.stringValue {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.createdAt = formatter.date(from: ts) ?? Date()
        } else {
            self.createdAt = Date()
        }
    }

    /// Convert to a Message for display
    func toMessage(myUserId: String?) -> Message {
        let isMe = senderUserId != nil && senderUserId == myUserId
        let role: Message.Role = isMe ? .user : .assistant
        let senderId = senderUserId ?? (senderAgentId.map { "agent:\($0)" })

        return Message(
            role: role,
            content: content,
            timestamp: createdAt,
            senderId: senderId,
            senderDisplayName: senderDisplayName,
            senderEmoji: senderEmoji.isEmpty ? nil : senderEmoji,
            mentions: mentions.isEmpty ? nil : mentions,
            replyToId: replyTo
        )
    }
}

// MARK: - Room Typing Event

struct RoomTypingEvent {
    let roomId: String
    let displayName: String

    init?(from payload: [String: AnyCodableValue]?) {
        guard let payload,
              let roomId = payload["roomId"]?.stringValue,
              let displayName = payload["displayName"]?.stringValue else { return nil }
        self.roomId = roomId
        self.displayName = displayName
    }
}
