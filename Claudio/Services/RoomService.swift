import Foundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "RoomService")

@Observable
final class RoomService {
    var rooms: [Room] = []
    var activeRoom: Room?
    var activeRoomMessages: [Message] = []
    var isLoading = false
    var connectionState: WebSocketClient.ConnectionState = .disconnected
    var typingIndicator: String?  // "Bart is typing..."

    // Backend config
    var backendURL: String {
        didSet { UserDefaults.standard.set(backendURL, forKey: "claudioBackendURL") }
    }
    var backendToken: String {
        didSet { UserDefaults.standard.set(backendToken, forKey: "claudioBackendToken") }
    }

    // Display name for rooms
    var displayName: String {
        didSet { UserDefaults.standard.set(displayName, forKey: "claudioDisplayName") }
    }
    var avatarEmoji: String {
        didSet { UserDefaults.standard.set(avatarEmoji, forKey: "claudioAvatarEmoji") }
    }

    var hasBackend: Bool { !backendURL.isEmpty }
    var isConnected: Bool { connectionState == .connected }

    private let webSocketClient = WebSocketClient()
    private var callbacksReady = false
    private var roomMessageHistories: [String: [Message]] = [:]  // roomID -> messages
    private var typingTimer: Timer?

    // My user ID (device identity)
    var myUserId: String { DeviceIdentity.shared.deviceId }

    init() {
        self.backendURL = UserDefaults.standard.string(forKey: "claudioBackendURL") ?? ""
        self.backendToken = UserDefaults.standard.string(forKey: "claudioBackendToken") ?? ""
        self.displayName = UserDefaults.standard.string(forKey: "claudioDisplayName") ?? ""
        self.avatarEmoji = UserDefaults.standard.string(forKey: "claudioAvatarEmoji") ?? ""
    }

    // MARK: - Connection

    func connect() {
        guard hasBackend else { return }
        log.info("connecting to backend: \(self.backendURL)")
        Task {
            if !callbacksReady {
                await setupCallbacks()
                callbacksReady = true
            }
            await webSocketClient.connect(serverURL: backendURL, token: backendToken)
        }
    }

    func disconnect() {
        Task { await webSocketClient.disconnect() }
    }

    private func setupCallbacks() async {
        await webSocketClient.setCallbacks(
            onStateChange: { [weak self] state in
                guard let self else { return }
                self.connectionState = state
                if state == .connected {
                    Task { await self.onConnected() }
                }
            },
            onChatEvent: { _ in },  // Not used for rooms
            onAgentEvent: { _ in }  // Not used for rooms
        )

        // Register for room events via the WebSocket client's event routing
        // We'll handle room events through a custom approach since WebSocketClient
        // currently only routes "chat" and "agent" events.
        // For now, we'll poll after connect. Phase 3 will add proper event handling.
    }

    @MainActor
    private func onConnected() async {
        log.info("backend connected")

        // Update display name if set
        if !displayName.isEmpty || !avatarEmoji.isEmpty {
            await updateProfile()
        }

        // Fetch room list
        await fetchRooms()
    }

    // MARK: - Room Operations

    @MainActor
    func fetchRooms() async {
        do {
            let response = try await webSocketClient.send(method: "rooms.list")
            guard response.ok, let payload = response.payload,
                  let roomsArr = payload["rooms"]?.arrayValue else {
                log.error("fetchRooms: invalid response")
                return
            }
            rooms = roomsArr.compactMap { Room(from: $0) }
            log.info("fetchRooms: got \(self.rooms.count) rooms")
        } catch {
            log.error("fetchRooms: \(error)")
        }
    }

    @MainActor
    func createRoom(name: String, emoji: String) async -> Room? {
        do {
            var params: [String: AnyCodableValue] = ["name": .string(name)]
            if !emoji.isEmpty {
                params["emoji"] = .string(emoji)
            }
            let response = try await webSocketClient.send(method: "rooms.create", params: params)
            guard response.ok, let payload = response.payload,
                  let roomValue = payload["room"] else {
                log.error("createRoom: invalid response")
                return nil
            }
            if let room = Room(from: roomValue) {
                rooms.insert(room, at: 0)
                log.info("createRoom: \(room.name) (\(room.id))")
                return room
            }
        } catch {
            log.error("createRoom: \(error)")
        }
        return nil
    }

    @MainActor
    func joinRoom(inviteCode: String) async -> Room? {
        do {
            let params: [String: AnyCodableValue] = ["inviteCode": .string(inviteCode)]
            let response = try await webSocketClient.send(method: "rooms.join", params: params)
            guard response.ok, let payload = response.payload,
                  let roomValue = payload["room"] else {
                log.error("joinRoom: invalid response")
                return nil
            }
            if let room = Room(from: roomValue) {
                if !rooms.contains(where: { $0.id == room.id }) {
                    rooms.insert(room, at: 0)
                }
                log.info("joinRoom: \(room.name)")
                return room
            }
        } catch {
            log.error("joinRoom: \(error)")
        }
        return nil
    }

    @MainActor
    func leaveRoom(_ roomId: String) async {
        do {
            let params: [String: AnyCodableValue] = ["roomId": .string(roomId)]
            _ = try await webSocketClient.send(method: "rooms.leave", params: params)
            rooms.removeAll { $0.id == roomId }
            if activeRoom?.id == roomId {
                activeRoom = nil
                activeRoomMessages = []
            }
        } catch {
            log.error("leaveRoom: \(error)")
        }
    }

    @MainActor
    func fetchRoomInfo(_ roomId: String) async -> Room? {
        do {
            let params: [String: AnyCodableValue] = ["roomId": .string(roomId)]
            let response = try await webSocketClient.send(method: "rooms.info", params: params)
            guard response.ok, let payload = response.payload,
                  let roomValue = payload["room"] else { return nil }
            return Room(from: roomValue)
        } catch {
            log.error("fetchRoomInfo: \(error)")
            return nil
        }
    }

    // MARK: - Messages

    @MainActor
    func enterRoom(_ room: Room) async {
        activeRoom = room
        activeRoomMessages = roomMessageHistories[room.id] ?? []
        await loadHistory(room.id)
    }

    @MainActor
    func exitRoom() {
        if let roomId = activeRoom?.id {
            roomMessageHistories[roomId] = activeRoomMessages
        }
        activeRoom = nil
        activeRoomMessages = []
    }

    @MainActor
    func loadHistory(_ roomId: String) async {
        do {
            var params: [String: AnyCodableValue] = [
                "roomId": .string(roomId),
                "limit": .int(50)
            ]
            if let firstMsg = activeRoomMessages.first {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                params["before"] = .string(formatter.string(from: firstMsg.timestamp))
            }

            let response = try await webSocketClient.send(method: "rooms.history", params: params)
            guard response.ok, let payload = response.payload,
                  let messagesArr = payload["messages"]?.arrayValue else { return }

            let newMessages = messagesArr.compactMap { msgValue -> Message? in
                guard let obj = msgValue.objectValue else { return nil }
                return parseRoomHistoryMessage(obj)
            }

            if activeRoomMessages.isEmpty {
                activeRoomMessages = newMessages
            } else {
                // Prepend older messages
                activeRoomMessages = newMessages + activeRoomMessages
            }

            roomMessageHistories[roomId] = activeRoomMessages
            log.info("loadHistory: \(newMessages.count) messages for room \(roomId)")
        } catch {
            log.error("loadHistory: \(error)")
        }
    }

    @MainActor
    func sendMessage(content: String, mentions: [String] = [], replyTo: String? = nil) async {
        guard let roomId = activeRoom?.id else { return }

        var params: [String: AnyCodableValue] = [
            "roomId": .string(roomId),
            "content": .string(content)
        ]
        if !mentions.isEmpty {
            params["mentions"] = .array(mentions.map { .string($0) })
        }
        if let replyTo {
            params["replyTo"] = .string(replyTo)
        }

        // Optimistically add the message
        let optimistic = Message(
            role: .user,
            content: content,
            senderId: myUserId,
            senderDisplayName: displayName.isEmpty ? "Me" : displayName,
            senderEmoji: avatarEmoji.isEmpty ? nil : avatarEmoji,
            mentions: mentions.isEmpty ? nil : mentions,
            replyToId: replyTo
        )
        activeRoomMessages.append(optimistic)

        do {
            _ = try await webSocketClient.send(method: "rooms.send", params: params)
        } catch {
            log.error("sendMessage: \(error)")
        }
    }

    // MARK: - Invites

    @MainActor
    func createInvite(roomId: String, maxUses: Int = 0) async -> String? {
        do {
            var params: [String: AnyCodableValue] = ["roomId": .string(roomId)]
            if maxUses > 0 {
                params["maxUses"] = .int(maxUses)
            }
            let response = try await webSocketClient.send(method: "rooms.createInvite", params: params)
            guard response.ok, let payload = response.payload else { return nil }
            return payload["code"]?.stringValue
        } catch {
            log.error("createInvite: \(error)")
            return nil
        }
    }

    // MARK: - Agents

    @MainActor
    func addAgent(roomId: String, openclawUrl: String, openclawToken: String, agentId: String, agentName: String, agentEmoji: String) async -> Bool {
        do {
            let params: [String: AnyCodableValue] = [
                "roomId": .string(roomId),
                "openclawUrl": .string(openclawUrl),
                "openclawToken": .string(openclawToken),
                "agentId": .string(agentId),
                "agentName": .string(agentName),
                "agentEmoji": .string(agentEmoji)
            ]
            let response = try await webSocketClient.send(method: "rooms.addAgent", params: params)
            if response.ok {
                // Refresh room info
                if let updated = await fetchRoomInfo(roomId) {
                    if let idx = rooms.firstIndex(where: { $0.id == roomId }) {
                        rooms[idx] = updated
                    }
                    if activeRoom?.id == roomId {
                        activeRoom = updated
                    }
                }
                return true
            }
        } catch {
            log.error("addAgent: \(error)")
        }
        return false
    }

    @MainActor
    func removeAgent(roomId: String, agentId: String, openclawUrl: String) async {
        do {
            let params: [String: AnyCodableValue] = [
                "roomId": .string(roomId),
                "agentId": .string(agentId),
                "openclawUrl": .string(openclawUrl)
            ]
            _ = try await webSocketClient.send(method: "rooms.removeAgent", params: params)
            // Refresh
            if let updated = await fetchRoomInfo(roomId) {
                if let idx = rooms.firstIndex(where: { $0.id == roomId }) {
                    rooms[idx] = updated
                }
                if activeRoom?.id == roomId {
                    activeRoom = updated
                }
            }
        } catch {
            log.error("removeAgent: \(error)")
        }
    }

    // MARK: - Profile

    @MainActor
    func updateProfile() async {
        guard isConnected else { return }
        do {
            var params: [String: AnyCodableValue] = [:]
            if !displayName.isEmpty {
                params["displayName"] = .string(displayName)
            }
            if !avatarEmoji.isEmpty {
                params["avatarEmoji"] = .string(avatarEmoji)
            }
            _ = try await webSocketClient.send(method: "user.update", params: params)
        } catch {
            log.error("updateProfile: \(error)")
        }
    }

    // MARK: - Event Handling

    func handleRoomMessageEvent(_ event: RoomMessage) {
        // Don't duplicate our own optimistic messages
        if event.senderUserId == myUserId { return }

        let message = event.toMessage(myUserId: myUserId)

        if activeRoom?.id == event.roomId {
            activeRoomMessages.append(message)
        }

        // Update in histories
        if roomMessageHistories[event.roomId] == nil {
            roomMessageHistories[event.roomId] = []
        }
        roomMessageHistories[event.roomId]?.append(message)

        // Update unread count
        if activeRoom?.id != event.roomId {
            if let idx = rooms.firstIndex(where: { $0.id == event.roomId }) {
                rooms[idx].unreadCount += 1
                rooms[idx].lastMessage = RoomLastMessage(
                    content: event.content.count > 100 ? String(event.content.prefix(100)) + "…" : event.content,
                    senderName: event.senderDisplayName,
                    senderEmoji: event.senderEmoji,
                    createdAt: ISO8601DateFormatter().string(from: event.createdAt)
                )
            }
        }
    }

    func handleTypingEvent(_ event: RoomTypingEvent) {
        guard activeRoom?.id == event.roomId else { return }
        typingIndicator = "\(event.displayName) is typing..."
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.typingIndicator = nil
            }
        }
    }

    // MARK: - Helpers

    private func parseRoomHistoryMessage(_ obj: [String: AnyCodableValue]) -> Message? {
        guard let content = obj["content"]?.stringValue else { return nil }

        let senderUserId = obj["senderUserId"]?.stringValue
        let senderAgentId = obj["senderAgentId"]?.stringValue
        let isMe = senderUserId != nil && senderUserId == myUserId
        let role: Message.Role = isMe ? .user : .assistant

        var timestamp = Date()
        if let ts = obj["createdAt"]?.stringValue {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let parsed = formatter.date(from: ts) {
                timestamp = parsed
            }
        }

        let senderId = senderUserId ?? senderAgentId.map { "agent:\($0)" }

        var mentions: [String]?
        if let mentionsStr = obj["mentions"]?.stringValue,
           let data = mentionsStr.data(using: .utf8),
           let parsed = try? JSONDecoder().decode([String].self, from: data) {
            mentions = parsed.isEmpty ? nil : parsed
        }

        return Message(
            role: role,
            content: content,
            timestamp: timestamp,
            senderId: senderId,
            senderDisplayName: obj["senderDisplayName"]?.stringValue,
            senderEmoji: obj["senderEmoji"]?.stringValue,
            mentions: mentions,
            replyToId: obj["replyTo"]?.stringValue
        )
    }
}
