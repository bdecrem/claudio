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

    // Per-agent chat history
    private var chatHistories: [String: [Message]] = [:]
    private var audioPlayer: AVAudioPlayer?
    private var pendingAgents: Set<String> = []

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

    var selectedAgent: String {
        didSet {
            guard oldValue != selectedAgent else { return }
            UserDefaults.standard.set(selectedAgent, forKey: "selectedAgent")
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

    init() {
        self.selectedAgent = UserDefaults.standard.string(forKey: "selectedAgent") ?? ""
        self.activeServerIndex = UserDefaults.standard.integer(forKey: "activeServerIndex")

        if let data = UserDefaults.standard.data(forKey: "savedServers"),
           let decoded = try? JSONDecoder().decode([CodableServer].self, from: data) {
            self.savedServers = decoded.map { server in
                var url = server.url
                if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
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

    private struct DecodedAgent: Decodable {
        let id: String
        let name: String
        let emoji: String?
        let color: String?
    }

    // MARK: - Server management

    func addServer(url: String, token: String) {
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "/"))
        guard !cleaned.isEmpty else { return }
        if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
            cleaned = "https://\(cleaned)"
        }
        savedServers.append(Server(url: cleaned, token: token))
        if savedServers.count == 1 {
            activeServerIndex = 0
        }
        Task { await fetchAgents() }
    }

    func updateServer(at index: Int, url: String, token: String) {
        guard savedServers.indices.contains(index) else { return }
        var cleaned = url.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "/"))
        if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
            cleaned = "https://\(cleaned)"
        }
        savedServers[index] = Server(
            url: cleaned,
            token: token
        )
        Task { await fetchAgents() }
    }

    func removeServer(at index: Int) {
        guard savedServers.indices.contains(index), index != activeServerIndex else { return }
        savedServers.remove(at: index)
        if activeServerIndex >= savedServers.count {
            activeServerIndex = max(0, savedServers.count - 1)
        }
        // Re-fetch since server indices shifted
        Task { await fetchAgents() }
    }

    func switchServer(to index: Int) {
        guard savedServers.indices.contains(index), index != activeServerIndex else { return }
        activeServerIndex = index
    }

    // MARK: - Auth helper

    private func authorizedRequest(url: URL, server: Server) -> URLRequest {
        var request = URLRequest(url: url)
        if !server.token.isEmpty {
            request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }
        return request
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

    // MARK: - Agents

    @MainActor
    func fetchAgents() async {
        guard !savedServers.isEmpty else {
            log.error("fetchAgents: no servers configured")
            agentFetchFailed = true
            return
        }

        var allAgents: [Agent] = []
        var anySuccess = false

        for (index, server) in savedServers.enumerated() {
            guard let url = URL(string: "\(server.url)/api/agents") else {
                log.error("fetchAgents: invalid URL from '\(server.url)'")
                continue
            }

            log.info("fetchAgents: GET \(url)")
            let request = authorizedRequest(url: url, server: server)

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    log.error("fetchAgents: not an HTTP response from \(server.url)")
                    continue
                }

                log.info("fetchAgents: \(server.url) status \(httpResponse.statusCode)")

                if httpResponse.statusCode == 401 {
                    connectionError = "Authentication required for \(server.url)."
                    continue
                }
                if httpResponse.statusCode == 403 {
                    connectionError = "Invalid token for \(server.url)."
                    continue
                }
                guard (200...299).contains(httpResponse.statusCode) else {
                    continue
                }

                struct AgentsResponse: Decodable {
                    let agents: [DecodedAgent]
                }

                let decoded = try JSONDecoder().decode(AgentsResponse.self, from: data)
                log.info("fetchAgents: \(server.url) returned \(decoded.agents.count) agents")

                for a in decoded.agents {
                    allAgents.append(Agent(
                        id: "\(index):\(a.id)",
                        agentId: a.id,
                        name: a.name,
                        emoji: a.emoji,
                        color: a.color,
                        serverIndex: index
                    ))
                }
                anySuccess = true
            } catch {
                log.error("fetchAgents: \(server.url) error — \(error)")
            }
        }

        agents = allAgents
        agentFetchFailed = !anySuccess
        if anySuccess { connectionError = nil }

        if selectedAgent.isEmpty || !agents.contains(where: { $0.id == selectedAgent }) {
            selectedAgent = agents.first?.id ?? ""
            log.info("fetchAgents: selected '\(self.selectedAgent)'")
        }
    }

    // MARK: - Chat

    func sendMessage(_ content: String, playVoice: Bool = false) {
        let userMessage = Message(role: .user, content: content)
        messages.append(userMessage)
        connectionError = nil
        persistChatHistories()

        let compositeId = selectedAgent
        let rawAgentId = selectedAgentId
        let server = selectedServer
        let history = messages.map { $0.apiRepresentation }

        log.info("sendMessage: agent='\(rawAgentId)' server='\(server?.url ?? "nil")' messages=\(history.count)")

        pendingAgents.insert(compositeId)
        isLoading = isLoadingCurrentAgent

        Task {
            await fetchResponse(compositeId: compositeId, agentId: rawAgentId, server: server, history: history, playVoice: playVoice)
        }
    }

    @MainActor
    private func fetchResponse(
        compositeId: String,
        agentId: String,
        server: Server?,
        history: [[String: String]],
        playVoice: Bool
    ) async {
        guard let server else {
            log.error("fetchResponse: no server")
            deliverResult(.failure("No server configured."), to: compositeId)
            return
        }
        guard let url = URL(string: "\(server.url)/api/chat/agent") else {
            log.error("fetchResponse: invalid URL from '\(server.url)'")
            deliverResult(.failure("Invalid server address."), to: compositeId)
            return
        }
        log.info("fetchResponse: POST \(url) agent='\(agentId)'")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.token.isEmpty {
            request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = ["messages": history]
        if !agentId.isEmpty {
            body["agent"] = agentId
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            deliverResult(.failure("Failed to encode request."), to: compositeId)
            return
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                deliverResult(.failure("Invalid response."), to: compositeId)
                return
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                deliverResult(.failure("Authentication failed. Check your token."), to: compositeId)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                deliverResult(.failure("Server error (\(httpResponse.statusCode))."), to: compositeId)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                deliverResult(.failure("Unexpected response format."), to: compositeId)
                return
            }

            deliverResult(.success(content), to: compositeId)

            if playVoice {
                await playTTS(for: content, agentId: agentId, server: server)
            }
        } catch let urlError as URLError {
            log.error("fetchResponse: URLError \(urlError.code.rawValue) — \(urlError.localizedDescription)")
            deliverResult(.failure("Can't connect to server."), to: compositeId)
        } catch {
            log.error("fetchResponse: error — \(error)")
            deliverResult(.failure("Connection error."), to: compositeId)
        }
    }

    private enum DeliveryResult {
        case success(String)
        case failure(String)
    }

    @MainActor
    private func deliverResult(_ result: DeliveryResult, to agentId: String) {
        pendingAgents.remove(agentId)

        let responseMessage: Message
        switch result {
        case .success(let content):
            responseMessage = Message(role: .assistant, content: content)
        case .failure(let error):
            responseMessage = Message(role: .assistant, content: error)
            if agentId == selectedAgent {
                connectionError = error
            }
        }

        if agentId == selectedAgent {
            messages.append(responseMessage)
        } else {
            var history = chatHistories[agentId] ?? []
            history.append(responseMessage)
            chatHistories[agentId] = history
        }

        isLoading = isLoadingCurrentAgent
        persistChatHistories()
    }

    // MARK: - TTS

    @MainActor
    private func playTTS(for text: String, agentId: String, server: Server) async {
        guard let url = URL(string: "\(server.url)/api/tts") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !server.token.isEmpty {
            request.setValue("Bearer \(server.token)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: String] = ["text": text, "agent": agentId]
        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else { return }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  !data.isEmpty else { return }

            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)

            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = TTSDelegate { [weak self] in
                DispatchQueue.main.async { self?.isSpeaking = false }
            }
            isSpeaking = true
            audioPlayer?.play()
        } catch {
            // TTS is enhancement — fail silently
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
