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
    }

    struct Agent: Identifiable, Equatable, Decodable {
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
        // Add https:// if no scheme provided
        if !cleaned.hasPrefix("http://") && !cleaned.hasPrefix("https://") {
            cleaned = "https://\(cleaned)"
        }
        let isFirst = savedServers.isEmpty
        savedServers.append(Server(url: cleaned, token: token))
        if isFirst {
            // activeServerIndex is already 0, just fetch agents
            activeServerIndex = 0
            agents.removeAll()
            selectedAgent = ""
            agentFetchFailed = false
            connectionError = nil
            Task { await fetchAgents() }
        } else {
            switchServer(to: savedServers.count - 1)
        }
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
        if index == activeServerIndex {
            Task { await fetchAgents() }
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
        // Save current agent's messages
        if !selectedAgent.isEmpty {
            chatHistories[selectedAgent] = messages
        }
        activeServerIndex = index
        messages.removeAll()
        agents.removeAll()
        selectedAgent = ""
        agentFetchFailed = false
        connectionError = nil
        chatHistories.removeAll()
        Task { await fetchAgents() }
    }

    // MARK: - Auth helper

    private func authorizedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let token = activeServer?.token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    // MARK: - Agents

    @MainActor
    func fetchAgents() async {
        guard let server = activeServer else {
            log.error("fetchAgents: no active server")
            agentFetchFailed = true
            return
        }
        let endpoint = server.url
        guard let url = URL(string: "\(endpoint)/api/agents") else {
            log.error("fetchAgents: invalid URL from '\(endpoint)'")
            agentFetchFailed = true
            return
        }

        log.info("fetchAgents: GET \(url)")
        let request = authorizedRequest(url: url)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                log.error("fetchAgents: not an HTTP response")
                agentFetchFailed = true
                return
            }

            log.info("fetchAgents: status \(httpResponse.statusCode)")

            if httpResponse.statusCode == 401 {
                agentFetchFailed = true
                connectionError = "Authentication required. Check your token."
                return
            }
            if httpResponse.statusCode == 403 {
                agentFetchFailed = true
                connectionError = "Invalid token. Check Settings."
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                agentFetchFailed = true
                connectionError = "Server error (\(httpResponse.statusCode))."
                return
            }

            struct AgentsResponse: Decodable {
                let agents: [Agent]
            }

            let decoded = try JSONDecoder().decode(AgentsResponse.self, from: data)
            log.info("fetchAgents: got \(decoded.agents.count) agents")
            agents = decoded.agents
            agentFetchFailed = false
            connectionError = nil

            if selectedAgent.isEmpty || !agents.contains(where: { $0.id == selectedAgent }) {
                selectedAgent = agents.first?.id ?? ""
                log.info("fetchAgents: selected '\(self.selectedAgent)'")
            }
        } catch {
            log.error("fetchAgents: error — \(error)")
            agentFetchFailed = true
        }
    }

    // MARK: - Chat

    func sendMessage(_ content: String, playVoice: Bool = false) {
        let userMessage = Message(role: .user, content: content)
        messages.append(userMessage)
        connectionError = nil

        let agentId = selectedAgent
        let server = activeServer
        let history = messages.map { $0.apiRepresentation }

        log.info("sendMessage: agent='\(agentId)' server='\(server?.url ?? "nil")' messages=\(history.count)")

        pendingAgents.insert(agentId)
        isLoading = isLoadingCurrentAgent

        Task {
            await fetchResponse(agentId: agentId, server: server, history: history, playVoice: playVoice)
        }
    }

    @MainActor
    private func fetchResponse(
        agentId: String,
        server: Server?,
        history: [[String: String]],
        playVoice: Bool
    ) async {
        guard let server else {
            log.error("fetchResponse: no server")
            deliverResult(.failure("No server configured."), to: agentId)
            return
        }
        guard let url = URL(string: "\(server.url)/api/chat/agent") else {
            log.error("fetchResponse: invalid URL from '\(server.url)'")
            deliverResult(.failure("Invalid server address."), to: agentId)
            return
        }
        log.info("fetchResponse: POST \(url)")

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
            deliverResult(.failure("Failed to encode request."), to: agentId)
            return
        }
        request.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                deliverResult(.failure("Invalid response."), to: agentId)
                return
            }

            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                deliverResult(.failure("Authentication failed. Check your token."), to: agentId)
                return
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                deliverResult(.failure("Server error (\(httpResponse.statusCode))."), to: agentId)
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                deliverResult(.failure("Unexpected response format."), to: agentId)
                return
            }

            deliverResult(.success(content), to: agentId)

            if playVoice {
                await playTTS(for: content, agentId: agentId, server: server)
            }
        } catch let urlError as URLError {
            log.error("fetchResponse: URLError \(urlError.code.rawValue) — \(urlError.localizedDescription)")
            deliverResult(.failure("Can't connect to server."), to: agentId)
        } catch {
            log.error("fetchResponse: error — \(error)")
            deliverResult(.failure("Connection error."), to: agentId)
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
    }

    func stopSpeaking() {
        audioPlayer?.stop()
        isSpeaking = false
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

// MARK: - AVAudioPlayerDelegate

private class TTSDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
