import Foundation
import AVFoundation

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

    private let defaultServer = "https://theaf-web.ngrok.io"

    var savedServers: [String] {
        didSet { UserDefaults.standard.set(savedServers, forKey: "savedServers") }
    }

    var serverAddress: String {
        didSet { UserDefaults.standard.set(serverAddress, forKey: "serverAddress") }
    }

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

    init() {
        let defaultAddr = UserDefaults.standard.string(forKey: "serverAddress") ?? defaultServer
        self.serverAddress = defaultAddr
        self.selectedAgent = UserDefaults.standard.string(forKey: "selectedAgent") ?? ""
        self.savedServers = UserDefaults.standard.stringArray(forKey: "savedServers") ?? [defaultAddr]
        // Ensure active server is in the list
        if !savedServers.contains(serverAddress) {
            savedServers.append(serverAddress)
        }
    }

    func switchServer(to address: String) {
        guard address != serverAddress else { return }
        serverAddress = address
        messages.removeAll()
        agents.removeAll()
        selectedAgent = ""
        agentFetchFailed = false
        connectionError = nil
        chatHistories.removeAll()
        Task { await fetchAgents() }
    }

    func addServer(_ address: String) {
        let cleaned = address.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .init(charactersIn: "/"))
        guard !cleaned.isEmpty, !savedServers.contains(cleaned) else { return }
        savedServers.append(cleaned)
    }

    func removeServer(at index: Int) {
        guard savedServers.indices.contains(index) else { return }
        let address = savedServers[index]
        guard address != serverAddress else { return } // can't delete active
        savedServers.remove(at: index)
    }

    struct Agent: Identifiable, Equatable, Decodable {
        let id: String
        let name: String
    }

    // MARK: - Agents

    @MainActor
    func fetchAgents() async {
        let endpoint = serverAddress.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/api/agents") else {
            agentFetchFailed = true
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                agentFetchFailed = true
                return
            }

            struct AgentsResponse: Decodable {
                let agents: [Agent]
            }

            let decoded = try JSONDecoder().decode(AgentsResponse.self, from: data)
            agents = decoded.agents
            agentFetchFailed = false
            connectionError = nil

            // Select first agent if current selection is invalid
            if selectedAgent.isEmpty || !agents.contains(where: { $0.id == selectedAgent }) {
                selectedAgent = agents.first?.id ?? ""
            }
        } catch {
            agentFetchFailed = true
        }
    }

    // Track which agents have in-flight requests
    private var pendingAgents: Set<String> = []

    /// Whether the currently-viewed agent is waiting for a response
    var isLoadingCurrentAgent: Bool {
        pendingAgents.contains(selectedAgent)
    }

    // MARK: - Chat

    func sendMessage(_ content: String, playVoice: Bool = false) {
        let userMessage = Message(role: .user, content: content)
        messages.append(userMessage)
        connectionError = nil

        // Snapshot everything at send time
        let agentId = selectedAgent
        let server = serverAddress
        let history = messages.map { $0.apiRepresentation }

        pendingAgents.insert(agentId)
        isLoading = isLoadingCurrentAgent

        Task {
            await fetchResponse(
                agentId: agentId,
                server: server,
                history: history,
                playVoice: playVoice
            )
        }
    }

    @MainActor
    private func fetchResponse(
        agentId: String,
        server: String,
        history: [[String: String]],
        playVoice: Bool
    ) async {
        let endpoint = server.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/api/chat/agent") else {
            deliverResult(.failure("Invalid server address. Check Settings."), to: agentId)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

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

            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                deliverResult(.failure("Server error (\(statusCode)). Check Settings."), to: agentId)
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
                await playTTS(for: content)
            }
        } catch is URLError {
            deliverResult(.failure("Can't connect to server. Check Settings."), to: agentId)
        } catch {
            deliverResult(.failure("Connection error."), to: agentId)
        }
    }

    private enum DeliveryResult {
        case success(String)
        case failure(String)
    }

    /// Route the response to the correct agent's history
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
            // Currently viewing this agent — append directly
            messages.append(responseMessage)
        } else {
            // Different tab — append to that agent's stored history
            var history = chatHistories[agentId] ?? []
            history.append(responseMessage)
            chatHistories[agentId] = history
        }

        isLoading = isLoadingCurrentAgent
    }

    // MARK: - TTS

    @MainActor
    private func playTTS(for text: String) async {
        let endpoint = serverAddress.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let url = URL(string: "\(endpoint)/api/tts") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: String] = ["text": text]
        if !selectedAgent.isEmpty {
            body["agent"] = selectedAgent
        }
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
            // TTS is an enhancement — fail silently, text is already shown
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
}

// MARK: - AVAudioPlayerDelegate

private class TTSDelegate: NSObject, AVAudioPlayerDelegate {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }
}
