import Foundation
import AVFoundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "ChatService")

@Observable
final class ChatService {
    var messages: [Message] = []
    var isLoading = false
    var isSpeaking = false
    var agents: [Agent] = []
    var agentFetchFailed = false
    var connectionError: String?
    var wsConnectionState: WebSocketClient.ConnectionState = .disconnected
    var unreadAgentIds: Set<String> = []

    // Per-agent chat history
    private var chatHistories: [String: [Message]] = [:]
    private var audioPlayer: AVAudioPlayer?
    private var ttsDelegate: TTSDelegate?
    private var queuedVoiceReplyAudio: [Data] = []
    private var pendingAgents: Set<String> = []
    private let webSocketClient = WebSocketClient()

    // Streaming message tracking
    private var streamingMessageId: UUID?
    private var pendingVoiceTTS: Bool = false
    private var voiceContinuation: CheckedContinuation<String, Error>?

    // MARK: - Server config

    struct Server: Equatable {
        var url: String
        var token: String
    }

    /// All saved servers (persisted as JSON in UserDefaults)
    var savedServers: [Server] {
        didSet { persistServers() }
    }

    /// Index of the active server in savedServers
    var activeServerIndex: Int {
        didSet { UserDefaults.standard.set(activeServerIndex, forKey: "activeServerIndex") }
    }

    var activeServer: Server? {
        guard savedServers.indices.contains(activeServerIndex) else { return nil }
        return savedServers[activeServerIndex]
    }

    /// Whether the user has configured at least one server
    var hasServer: Bool { !savedServers.isEmpty }

    var hiddenAgentIds: Set<String> {
        didSet {
            if let data = try? JSONEncoder().encode(hiddenAgentIds) {
                UserDefaults.standard.set(data, forKey: "hiddenAgentIds")
            }
        }
    }

    var visibleAgents: [Agent] {
        agents.filter { !hiddenAgentIds.contains($0.id) }
    }

    func toggleAgentVisibility(_ agentId: String) {
        if hiddenAgentIds.contains(agentId) {
            hiddenAgentIds.remove(agentId)
        } else {
            // Don't hide if it's the last visible agent
            let visibleCount = agents.filter { !hiddenAgentIds.contains($0.id) }.count
            guard visibleCount > 1 else { return }
            hiddenAgentIds.insert(agentId)
            // If hiding the selected agent, switch to first visible
            if selectedAgent == agentId {
                let visible = agents.filter { !hiddenAgentIds.contains($0.id) }
                if let first = visible.first {
                    selectedAgent = first.id
                }
            }
        }
    }

    var selectedAgent: String {
        didSet {
            guard oldValue != selectedAgent else { return }
            UserDefaults.standard.set(selectedAgent, forKey: "selectedAgent")
            unreadAgentIds.remove(selectedAgent)
            if !oldValue.isEmpty {
                chatHistories[oldValue] = messages
            }
            messages = chatHistories[selectedAgent] ?? []
            isLoading = isLoadingCurrentAgent
            connectionError = nil
        }
    }

    var isLoadingCurrentAgent: Bool {
        pendingAgents.contains(selectedAgent)
    }

    var isConnected: Bool {
        wsConnectionState == .connected
    }

    init() {
        self.selectedAgent = UserDefaults.standard.string(forKey: "selectedAgent") ?? ""
        self.activeServerIndex = UserDefaults.standard.integer(forKey: "activeServerIndex")

        if let hiddenData = UserDefaults.standard.data(forKey: "hiddenAgentIds"),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: hiddenData) {
            self.hiddenAgentIds = decoded
        } else {
            self.hiddenAgentIds = []
        }

        if let data = UserDefaults.standard.data(forKey: "savedServers"),
           let decoded = try? JSONDecoder().decode([CodableServer].self, from: data) {
            self.savedServers = decoded.map { server in
                var url = server.url
                if !url.hasPrefix("http://") && !url.hasPrefix("https://") &&
                   !url.hasPrefix("ws://") && !url.hasPrefix("wss://") {
                    url = "https://\(url)"
                }
                return Server(url: url, token: server.token)
            }
        } else {
            self.savedServers = []
        }

        // Restore chat histories if last session was <24h ago
        restoreChatHistories()
    }

    struct Agent: Identifiable, Equatable {
        let id: String          // unique key: "serverIndex:agentId"
        let agentId: String     // raw agent id sent to the API
        let name: String
        let emoji: String?
        let color: String?
        let serverIndex: Int    // which server this agent belongs to
    }

    // MARK: - Server management

    func addServer(url: String, token: String) {
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "/"))
        guard !cleaned.isEmpty else { return }
        if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") &&
           !cleaned.hasPrefix("ws://") && !cleaned.hasPrefix("wss://") {
            cleaned = "https://\(cleaned)"
        }
        savedServers.append(Server(url: cleaned, token: token))
        if savedServers.count == 1 {
            activeServerIndex = 0
        }
        connectWebSocket()
    }

    func updateServer(at index: Int, url: String, token: String) {
        guard savedServers.indices.contains(index) else { return }
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "/"))
        if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") &&
           !cleaned.hasPrefix("ws://") && !cleaned.hasPrefix("wss://") {
            cleaned = "https://\(cleaned)"
        }
        savedServers[index] = Server(
            url: cleaned,
            token: token
        )
        if index == activeServerIndex {
            connectWebSocket()
        }
    }

    func removeServer(at index: Int) {
        guard savedServers.indices.contains(index), index != activeServerIndex else { return }
        savedServers.remove(at: index)
        if activeServerIndex >= savedServers.count {
            activeServerIndex = max(0, savedServers.count - 1)
        }
    }

    func switchServer(to index: Int) {
        guard savedServers.indices.contains(index), index != activeServerIndex else { return }
        activeServerIndex = index
        connectWebSocket()
    }

    /// Find the server for a given agent
    func server(for agent: Agent) -> Server? {
        guard savedServers.indices.contains(agent.serverIndex) else { return nil }
        return savedServers[agent.serverIndex]
    }

    /// Find the server for the currently selected agent
    var selectedServer: Server? {
        guard let agent = agents.first(where: { $0.id == selectedAgent }) else {
            return activeServer
        }
        return server(for: agent)
    }

    /// Find the raw agent ID for the currently selected agent
    var selectedAgentId: String {
        agents.first(where: { $0.id == selectedAgent })?.agentId ?? selectedAgent
    }

    /// Session key for current agent (format: "agent:{agentId}:main")
    var currentSessionKey: String {
        "agent:\(selectedAgentId):main"
    }

    // MARK: - WebSocket Connection

    private var callbacksReady = false

    func connectWebSocket() {
        guard let server = activeServer else {
            log.error("connectWebSocket: no active server")
            return
        }

        log.info("connectWebSocket: \(server.url)")
        Task {
            if !callbacksReady {
                await setupWebSocketCallbacks()
                callbacksReady = true
            }
            await webSocketClient.connect(serverURL: server.url, token: server.token)
        }
    }

    func disconnectWebSocket() {
        Task { await webSocketClient.disconnect() }
    }

    private func setupWebSocketCallbacks() async {
        await webSocketClient.setCallbacks(
            onStateChange: { [weak self] state in
                guard let self else { return }
                self.wsConnectionState = state
                log.info("WS state: \(String(describing: state))")

                switch state {
                case .connected:
                    self.connectionError = nil
                    Task { await self.onWebSocketConnected() }

                case .pairingRequired:
                    self.connectionError = "Device pairing required. Approve this device on your server."
                    self.agentFetchFailed = true

                case .error(let msg):
                    self.connectionError = msg

                case .disconnected:
                    break

                case .connecting:
                    break
                }
            },
            onChatEvent: { [weak self] event in
                guard let self else { return }
                self.handleChatEvent(event)
            },
            onAgentEvent: { [weak self] event in
                guard let self else { return }
                self.handleAgentEvent(event)
            }
        )
    }

    @MainActor
    private func onWebSocketConnected() async {
        // Fetch agents via WebSocket
        await fetchAgentsViaWS()

        // Load chat history
        await loadChatHistory()

        // Register APNs token if available
        await NotificationService.shared.registerTokenIfNeeded(via: webSocketClient)
    }

    @MainActor
    private func fetchAgentsViaWS() async {
        do {
            let wsAgents = try await webSocketClient.agentsList()
            log.info("fetchAgentsViaWS: got \(wsAgents.count) agents")

            var allAgents: [Agent] = []
            for a in wsAgents {
                allAgents.append(Agent(
                    id: "\(activeServerIndex):\(a.id)",
                    agentId: a.id,
                    name: a.name,
                    emoji: a.emoji,
                    color: a.color,
                    serverIndex: activeServerIndex
                ))
            }

            agents = allAgents
            agentFetchFailed = false
            connectionError = nil

            if selectedAgent.isEmpty || !agents.contains(where: { $0.id == selectedAgent }) {
                selectedAgent = agents.first?.id ?? ""
                log.info("fetchAgentsViaWS: selected '\(self.selectedAgent)'")
            }
        } catch {
            log.error("fetchAgentsViaWS: \(error)")
            agentFetchFailed = true
        }
    }

    @MainActor
    private func loadChatHistory() async {
        do {
            let historyMessages = try await webSocketClient.chatHistory(sessionKey: currentSessionKey, limit: 50)
            log.info("loadChatHistory: got \(historyMessages.count) messages")

            guard !historyMessages.isEmpty else { return }

            // Only load if we don't already have messages (don't overwrite active session)
            if messages.isEmpty {
                messages = historyMessages.map { msg in
                    let role: Message.Role = msg.role == "user" ? .user : .assistant
                    return Message(
                        role: role,
                        content: msg.content,
                        timestamp: msg.timestamp ?? Date()
                    )
                }
                persistChatHistories()
            }
        } catch {
            log.error("loadChatHistory: \(error)")
        }
    }

    // MARK: - Chat Events

    /// Map a sessionKey like "agent:mave:main" to the composite agent ID like "0:mave"
    private func compositeIdFromSessionKey(_ sessionKey: String) -> String? {
        let parts = sessionKey.split(separator: ":")
        guard parts.count >= 2, parts[0] == "agent" else { return nil }
        let rawAgentId = String(parts[1])
        return agents.first(where: { $0.agentId == rawAgentId })?.id
    }

    @MainActor
    private func handleChatEvent(_ event: ChatEvent) {
        // Mark as unread if this event is for a non-selected agent
        if !event.sessionKey.isEmpty,
           let compositeId = compositeIdFromSessionKey(event.sessionKey),
           compositeId != selectedAgent {
            unreadAgentIds.insert(compositeId)
            // Store the message in the correct agent's history
            if event.state == .delta, let text = event.text {
                if chatHistories[compositeId] == nil {
                    chatHistories[compositeId] = []
                }
                // Only append if there's no streaming message for this agent yet
                // (handled below for the selected agent; for background agents, just update history on final)
            }
            if event.state == .final_, let text = event.text, !text.isEmpty {
                if chatHistories[compositeId] == nil {
                    chatHistories[compositeId] = []
                }
                chatHistories[compositeId]?.append(Message(role: .assistant, content: text))
                persistChatHistories()
            }
            return
        }

        switch event.state {
        case .delta:
            guard let text = event.text else { return }

            if let msgId = streamingMessageId,
               let idx = messages.firstIndex(where: { $0.id == msgId }) {
                // Update existing streaming message — delta contains FULL text so far
                messages[idx].content = text
            } else {
                // First delta — create streaming placeholder
                let placeholder = Message(role: .assistant, content: text, isStreaming: true)
                messages.append(placeholder)
                streamingMessageId = placeholder.id
            }

        case .final_:
            let finalText = event.text ?? ""

            if let msgId = streamingMessageId,
               let idx = messages.firstIndex(where: { $0.id == msgId }) {
                messages[idx].content = finalText
                messages[idx].isStreaming = false
            } else {
                // Got final without any deltas
                messages.append(Message(role: .assistant, content: finalText))
            }

            let compositeId = selectedAgent
            pendingAgents.remove(compositeId)
            isLoading = isLoadingCurrentAgent
            streamingMessageId = nil
            persistChatHistories()

            // Handle voice continuation
            if let continuation = voiceContinuation {
                voiceContinuation = nil
                pendingVoiceTTS = false
                let attachments = event.audioAttachments
                let server = selectedServer
                Task { [weak self] in
                    guard let self else { return }
                    let audioData = await self.extractPlayableMP3Data(from: attachments, server: server)
                    await MainActor.run {
                        if let audioData {
                            self.queuedVoiceReplyAudio.append(audioData)
                            continuation.resume(returning: finalText)
                        } else {
                            continuation.resume(throwing: WebSocketError.serverError("Voice response missing playable MP3 attachment."))
                        }
                    }
                }
            }

            // Handle inline voice TTS
            if pendingVoiceTTS {
                pendingVoiceTTS = false
                let attachments = event.audioAttachments
                let server = selectedServer
                Task { [weak self] in
                    guard let self else { return }
                    if let audioData = await self.extractPlayableMP3Data(from: attachments, server: server) {
                        _ = await self.playAudioData(audioData, source: "inline-voice-mp3")
                    } else {
                        await MainActor.run {
                            self.connectionError = "Voice response missing playable MP3 attachment."
                        }
                    }
                }
            }

        case .aborted:
            if let msgId = streamingMessageId,
               let idx = messages.firstIndex(where: { $0.id == msgId }) {
                if let text = event.text, !text.isEmpty {
                    messages[idx].content = text
                }
                messages[idx].isStreaming = false
            }

            let compositeId = selectedAgent
            pendingAgents.remove(compositeId)
            isLoading = isLoadingCurrentAgent
            streamingMessageId = nil
            persistChatHistories()

            if let continuation = voiceContinuation {
                voiceContinuation = nil
                pendingVoiceTTS = false
                continuation.resume(returning: event.text ?? "")
            }

        case .error:
            let errorMsg = event.errorMessage ?? "Something went wrong."

            if let msgId = streamingMessageId,
               let idx = messages.firstIndex(where: { $0.id == msgId }) {
                messages[idx].content = errorMsg
                messages[idx].isStreaming = false
            }

            connectionError = errorMsg
            let compositeId = selectedAgent
            pendingAgents.remove(compositeId)
            isLoading = isLoadingCurrentAgent
            streamingMessageId = nil
            persistChatHistories()

            if let continuation = voiceContinuation {
                voiceContinuation = nil
                pendingVoiceTTS = false
                continuation.resume(throwing: WebSocketError.serverError(errorMsg))
            }
        }
    }

    // MARK: - Agent Events (Tool Calls)

    @MainActor
    private func handleAgentEvent(_ event: AgentEvent) {
        // Only handle tool stream events
        guard event.stream == "tool" else { return }

        switch event.phase {
        case "start":
            guard let callId = event.callId else { return }
            let toolCall = ToolCall(
                id: callId,
                name: event.toolName ?? "tool",
                args: event.args ?? [:]
            )

            // Attach to the current streaming message, or create one
            if let msgId = streamingMessageId,
               let idx = messages.firstIndex(where: { $0.id == msgId }) {
                messages[idx].toolCalls.append(toolCall)
            } else {
                // Create a streaming placeholder with the tool call
                var placeholder = Message(role: .assistant, content: "", isStreaming: true)
                placeholder.toolCalls.append(toolCall)
                messages.append(placeholder)
                streamingMessageId = placeholder.id
            }

        case "result":
            // Find the tool call by callId and mark it complete
            guard let callId = event.callId else { return }
            if let msgId = streamingMessageId,
               let msgIdx = messages.firstIndex(where: { $0.id == msgId }),
               let tcIdx = messages[msgIdx].toolCalls.firstIndex(where: { $0.id == callId }) {
                messages[msgIdx].toolCalls[tcIdx].output = event.meta ?? (event.isError ? "error" : "done")
            }

        default:
            break
        }
    }

    // MARK: - Chat

    func sendMessage(_ content: String, playVoice: Bool = false, imageAttachments: [ImageAttachment] = []) {
        let userMessage = Message(role: .user, content: content, imageAttachments: imageAttachments)
        messages.append(userMessage)
        connectionError = nil
        persistChatHistories()

        let compositeId = selectedAgent
        let sessionKey = currentSessionKey
        pendingAgents.insert(compositeId)
        isLoading = isLoadingCurrentAgent
        pendingVoiceTTS = playVoice

        // Convert image attachments to base64 dicts for the wire
        let wireAttachments: [[String: String]] = imageAttachments.map { img in
            [
                "fileName": img.filename,
                "mimeType": img.contentType,
                "content": img.data.base64EncodedString()
            ]
        }

        log.info("sendMessage: '\(content.prefix(50))' sessionKey=\(sessionKey) attachments=\(wireAttachments.count)")

        Task {
            do {
                _ = try await webSocketClient.chatSend(sessionKey: sessionKey, message: content, attachments: wireAttachments)
            } catch {
                log.error("sendMessage failed: \(error)")
                await MainActor.run {
                    self.connectionError = error.localizedDescription
                    self.pendingAgents.remove(compositeId)
                    self.isLoading = self.isLoadingCurrentAgent
                    self.pendingVoiceTTS = false
                }
            }
        }
    }

    /// Send a message and collect the full response (for voice mode)
    func sendForVoice(
        serverURL: String,
        token: String,
        agentId: String,
        messages: [[String: String]]
    ) async throws -> String {
        // Extract the last user message
        guard let lastMessage = messages.last, let content = lastMessage["content"] else {
            throw WebSocketError.serverError("No message to send")
        }

        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                self.voiceContinuation = continuation
                // Send via WebSocket — response comes back via chat event
                Task {
                    do {
                        _ = try await self.webSocketClient.chatSend(sessionKey: self.currentSessionKey, message: content)
                    } catch {
                        if let cont = self.voiceContinuation {
                            self.voiceContinuation = nil
                            cont.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    // MARK: - TTS

    @MainActor
    func playTTSPublic(for text: String, agentId: String, server: Server) async {
        guard !queuedVoiceReplyAudio.isEmpty else {
            connectionError = "Voice response missing playable MP3 attachment."
            return
        }
        let data = queuedVoiceReplyAudio.removeFirst()
        _ = await playAudioData(data, source: "voice-reply-mp3")
    }

    /// Convert ws:// or wss:// URLs to http:// or https:// for HTTP endpoints (TTS)
    private func httpURL(for serverURL: String) -> String {
        if serverURL.hasPrefix("wss://") {
            return "https://" + serverURL.dropFirst("wss://".count)
        } else if serverURL.hasPrefix("ws://") {
            return "http://" + serverURL.dropFirst("ws://".count)
        }
        return serverURL
    }

    @MainActor
    private func playAudioAttachments(_ attachments: [ChatEvent.AudioAttachment], server: Server?) async -> Bool {
        guard !attachments.isEmpty else { return false }

        for attachment in attachments {
            if let base64 = attachment.base64Data,
               let data = Data(base64Encoded: base64),
               !data.isEmpty {
                if await playAudioData(data, source: "chat-attachment-base64") {
                    return true
                }
            }

            if let urlString = attachment.url,
               let data = await fetchAudioAttachmentData(urlString: urlString, server: server),
               !data.isEmpty {
                if await playAudioData(data, source: "chat-attachment-url") {
                    return true
                }
            }

            if let mediaPath = attachment.mediaPath, !mediaPath.isEmpty {
                log.info("Audio attachment includes media path reference (not directly fetchable here): \(mediaPath)")
            }
        }

        return false
    }

    @MainActor
    private func extractPlayableMP3Data(from attachments: [ChatEvent.AudioAttachment], server: Server?) async -> Data? {
        guard !attachments.isEmpty else { return nil }

        for attachment in attachments {
            let mime = attachment.mimeType?.lowercased() ?? ""
            let likelyMP3 = mime.contains("audio/mpeg")
                || mime.contains("audio/mp3")
                || (attachment.url?.lowercased().contains(".mp3") == true)
                || (attachment.mediaPath?.lowercased().contains(".mp3") == true)

            guard likelyMP3 else { continue }

            if let base64 = attachment.base64Data,
               let data = Data(base64Encoded: base64),
               !data.isEmpty {
                return data
            }

            if let urlString = attachment.url,
               let data = await fetchAudioAttachmentData(urlString: urlString, server: server),
               !data.isEmpty {
                return data
            }
        }

        return nil
    }

    @MainActor
    private func fetchAudioAttachmentData(urlString: String, server: Server?) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        if let host = url.host?.lowercased(), host.contains("ngrok") {
            request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        }
        if let server, !server.token.isEmpty {
            request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if !contentType.isEmpty, !contentType.hasPrefix("audio/") {
                log.error("Audio attachment fetch returned non-audio content type: \(contentType)")
                return nil
            }
            return data
        } catch {
            log.error("Failed to fetch audio attachment URL: \(error)")
            return nil
        }
    }

    @MainActor
    private func playAudioData(_ data: Data, source: String) async -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(data: data)

            // Await playback completion so callers (voice mode) don't
            // immediately start the mic and switch audio session to .record.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let delegate = TTSDelegate {
                    continuation.resume()
                }
                self.ttsDelegate = delegate
                audioPlayer?.delegate = delegate
                isSpeaking = true
                audioPlayer?.play()
                log.info("playAudioData[\(source)]: playing \(self.audioPlayer?.duration ?? 0)s")
            }
            self.ttsDelegate = nil
            isSpeaking = false
            log.info("playAudioData[\(source)]: done")
            return true
        } catch {
            log.error("playAudioData[\(source)] failed: \(error)")
            isSpeaking = false
            return false
        }
    }

    // MARK: - Helpers

    func clearMessages() {
        messages.removeAll()
        chatHistories[selectedAgent] = nil
        connectionError = nil
        persistChatHistories()
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        isSpeaking = false
    }

    func appendVoiceMessage(role: Message.Role, content: String) {
        let message = Message(role: role, content: content)
        messages.append(message)
        persistChatHistories()
    }

    // MARK: - Chat persistence

    func persistChatHistories() {
        // Snapshot current agent's messages into histories
        var histories = chatHistories
        if !selectedAgent.isEmpty {
            histories[selectedAgent] = messages
        }

        let payload = CodableChatState(
            histories: histories,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: "chatState")
        }
    }

    private func restoreChatHistories() {
        guard let data = UserDefaults.standard.data(forKey: "chatState"),
              let state = try? JSONDecoder().decode(CodableChatState.self, from: data) else { return }

        let age = Date().timeIntervalSince(state.savedAt)
        guard age < 24 * 60 * 60 else {
            // Stale — discard
            UserDefaults.standard.removeObject(forKey: "chatState")
            return
        }

        chatHistories = state.histories
        if !selectedAgent.isEmpty {
            messages = chatHistories[selectedAgent] ?? []
        }
        let count = chatHistories.count
        log.info("Restored chat histories (\(count) agents, \(Int(age))s old)")
    }

    private func persistServers() {
        let codable = savedServers.map { CodableServer(url: $0.url, token: $0.token) }
        if let data = try? JSONEncoder().encode(codable) {
            UserDefaults.standard.set(data, forKey: "savedServers")
        }
    }
}

// MARK: - Codable helper (Server is not Codable directly to keep it simple)

private struct CodableServer: Codable {
    let url: String
    let token: String
}

private struct CodableChatState: Codable {
    let histories: [String: [Message]]
    let savedAt: Date
}

// MARK: - AVAudioPlayerDelegate

private class TTSDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
