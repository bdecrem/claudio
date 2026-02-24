import Foundation
import Combine
import Hume
import os

private let log = Logger(subsystem: "com.claudio.app", category: "EVIService")

@Observable
final class EVIService {

    // MARK: - State

    enum State: Equatable {
        case idle
        case connecting
        case listening
        case thinking
        case speaking
        case error(String)
    }

    var state: State = .idle
    var audioLevel: Float = 0
    var transcript = ""

    var onUserMessage: ((String) -> Void)?
    var onAssistantMessage: ((String) -> Void)?

    // MARK: - Private

    private var humeClient: HumeClient?
    private var voiceProvider: VoiceProvider?
    private var stateCancellable: AnyCancellable?

    // Accumulate assistant text across interim messages
    private var pendingAssistantText = ""

    // MARK: - Config

    struct VoiceConfig {
        let configId: String
        let apiKey: String
    }

    func fetchConfig(serverURL: String, token: String) async throws -> VoiceConfig {
        guard let url = URL(string: "\(serverURL)/api/voice/config") else {
            throw EVIError.invalidURL
        }

        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw EVIError.configFetchFailed
        }

        struct ConfigResponse: Decodable {
            let configId: String
            let apiKey: String
        }

        let config = try JSONDecoder().decode(ConfigResponse.self, from: data)
        return VoiceConfig(configId: config.configId, apiKey: config.apiKey)
    }

    // MARK: - Connection

    @MainActor
    func connect(config: VoiceConfig) async {
        state = .connecting

        let client = HumeClient(options: .apiKey(key: config.apiKey))
        self.humeClient = client

        let provider = VoiceProviderFactory.shared.getVoiceProvider(client: client)
        self.voiceProvider = provider

        let delegate = Delegate(service: self)
        self._delegate = delegate
        provider.delegate = delegate
        provider.isOutputMeteringEnabled = true

        // Observe VoiceProviderState for disconnect detection
        stateCancellable = provider.state.sink { [weak self] providerState in
            guard let self else { return }
            if providerState == .disconnected && self.state != .idle {
                DispatchQueue.main.async {
                    if case .error = self.state { return }
                    self.state = .idle
                }
            }
        }

        do {
            try await provider.connect(
                with: ChatConnectOptions(configId: config.configId),
                sessionSettings: SessionSettings(
                    audio: nil,
                    builtinTools: nil,
                    context: nil,
                    customSessionId: nil,
                    languageModelApiKey: nil,
                    systemPrompt: nil,
                    tools: nil,
                    variables: nil,
                    voiceId: nil
                )
            )
            log.info("EVI connected")
            state = .listening
        } catch {
            log.error("EVI connect failed: \(error)")
            state = .error("Failed to connect to voice service.")
        }
    }

    @MainActor
    func disconnect() async {
        stateCancellable?.cancel()
        stateCancellable = nil

        if let provider = voiceProvider {
            await provider.disconnect()
        }

        voiceProvider = nil
        humeClient = nil
        _delegate = nil
        transcript = ""
        audioLevel = 0
        pendingAssistantText = ""
        state = .idle
        log.info("EVI disconnected")
    }

    // MARK: - Delegate holder (strong ref to prevent dealloc)

    private var _delegate: Delegate?

    private class Delegate: VoiceProviderDelegate {
        weak var service: EVIService?

        init(service: EVIService) {
            self.service = service
        }

        func voiceProvider(_ voiceProvider: any VoiceProvidable, didProduceEvent event: SubscribeEvent) {
            guard let service else { return }
            DispatchQueue.main.async {
                service.handleEvent(event)
            }
        }

        func voiceProvider(_ voiceProvider: any VoiceProvidable, didProduceError error: VoiceProviderError) {
            guard let service else { return }
            log.error("EVI error: \(String(describing: error))")
            DispatchQueue.main.async {
                service.state = .error("Voice connection error.")
            }
        }

        func voiceProvider(_ voiceProvider: any VoiceProvidable, didReceieveAudioOutputMeter audioInputMeter: Float) {
            guard let service else { return }
            DispatchQueue.main.async {
                service.audioLevel = audioInputMeter
            }
        }

        func voiceProviderDidConnect(_ voiceProvider: any VoiceProvidable) {
            log.info("EVI delegate: connected")
        }

        func voiceProviderDidDisconnect(_ voiceProvider: any VoiceProvidable) {
            guard let service else { return }
            log.info("EVI delegate: disconnected")
            DispatchQueue.main.async {
                if case .error = service.state { return }
                service.state = .idle
            }
        }
    }

    // MARK: - Event handling

    @MainActor
    private func handleEvent(_ event: SubscribeEvent) {
        switch event {
        case .userMessage(let msg):
            if let content = msg.message.content {
                transcript = content
            }
            if !msg.interim {
                // Final user transcript
                let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    onUserMessage?(text)
                }
                state = .thinking
                transcript = ""
            }

        case .assistantMessage(let msg):
            if let content = msg.message.content {
                pendingAssistantText = content
            }

        case .audioOutput:
            if state != .speaking {
                state = .speaking
            }

        case .userInterruption:
            // User interrupted — SDK stops playback automatically
            if !pendingAssistantText.isEmpty {
                onAssistantMessage?(pendingAssistantText)
                pendingAssistantText = ""
            }
            state = .listening
            audioLevel = 0

        case .assistantEnd:
            if !pendingAssistantText.isEmpty {
                onAssistantMessage?(pendingAssistantText)
                pendingAssistantText = ""
            }
            state = .listening
            audioLevel = 0

        case .chatMetadata(let meta):
            log.info("EVI chat: \(meta.chatId)")

        case .webSocketError(let wsError):
            log.error("EVI WS error: \(String(describing: wsError))")
            state = .error("Voice connection error.")

        default:
            break
        }
    }

    // MARK: - Errors

    enum EVIError: LocalizedError {
        case invalidURL
        case configFetchFailed

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "Invalid server URL."
            case .configFetchFailed: return "Failed to fetch voice configuration."
            }
        }
    }
}
