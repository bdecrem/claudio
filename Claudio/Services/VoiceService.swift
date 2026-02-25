import Foundation
import AVFoundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "VoiceService")

@Observable
final class VoiceService: NSObject, AVAudioPlayerDelegate {

    // MARK: - State

    enum State: Equatable {
        case idle
        case listening
        case sending
        case speaking
        case error(String)
    }

    var state: State = .idle
    var sessionMessages: [(role: String, content: String)] = []
    var liveText = ""
    var audioLevel: Float = 0

    // MARK: - Private

    private var speechRecognizer: SpeechRecognizer?
    private var audioPlayer: AVAudioPlayer?
    private var observationTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    // Context needed for API calls
    private var serverURL = ""
    private var token = ""
    private var agentId = ""
    private var chatHistory: [[String: String]] = []

    override init() {
        super.init()
    }

    // MARK: - Public API

    @MainActor
    func start(serverURL: String, token: String, agentId: String, chatHistory: [[String: String]], speechRecognizer: SpeechRecognizer) {
        self.serverURL = serverURL
        self.token = token
        self.agentId = agentId
        self.chatHistory = chatHistory
        self.speechRecognizer = speechRecognizer

        startListening()
    }

    @MainActor
    func stop() {
        sendTask?.cancel()
        sendTask = nil
        observationTask?.cancel()
        observationTask = nil
        audioPlayer?.stop()
        audioPlayer = nil
        if let sr = speechRecognizer, sr.isListening {
            _ = sr.stopListening()
        }
        speechRecognizer = nil
        liveText = ""
        audioLevel = 0
        state = .idle
    }

    @MainActor
    func flushPending() {
        let trimmed = liveText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            sessionMessages.append((role: "user", content: trimmed))
        }
        liveText = ""
    }

    // MARK: - Listening

    @MainActor
    private func startListening() {
        guard let sr = speechRecognizer else { return }

        liveText = ""
        state = .listening

        sr.startListening()

        // Poll speech recognizer state
        observationTask?.cancel()
        observationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    guard let sr = self.speechRecognizer else { return }
                    self.liveText = sr.transcript
                    self.audioLevel = sr.audioLevel

                    // SpeechRecognizer auto-stops after 2s silence
                    if !sr.isListening && self.state == .listening {
                        let text = self.liveText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            self.sendTranscript(text)
                        } else {
                            // No speech detected, restart listening
                            self.startListening()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Send & TTS

    @MainActor
    private func sendTranscript(_ text: String) {
        observationTask?.cancel()
        observationTask = nil

        sessionMessages.append((role: "user", content: text))
        liveText = ""
        state = .sending

        let voicePrefix = "[Voice message — respond concisely in 1-3 spoken sentences, no markdown] "
        let prefixedText = voicePrefix + text

        var allMessages = chatHistory
        for msg in sessionMessages.dropLast() {
            allMessages.append(["role": msg.role, "content": msg.content])
        }
        allMessages.append(["role": "user", "content": prefixedText])

        sendTask = Task { [weak self] in
            guard let self else { return }
            await self.performSendAndSpeak(messages: allMessages)
        }
    }

    @MainActor
    private func performSendAndSpeak(messages: [[String: String]]) async {
        guard let chatURL = URL(string: "\(serverURL)/api/chat/agent/") else {
            state = .error("Invalid server URL.")
            return
        }

        var chatRequest = URLRequest(url: chatURL)
        chatRequest.httpMethod = "POST"
        chatRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            chatRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = ["messages": messages]
        if !agentId.isEmpty {
            body["agent"] = agentId
        }

        guard let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            state = .error("Failed to encode request.")
            return
        }
        chatRequest.httpBody = httpBody

        do {
            let (data, response) = try await URLSession.shared.data(for: chatRequest)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                log.error("Chat request failed")
                state = .error("Server error.")
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                state = .error("Unexpected response.")
                return
            }

            guard !Task.isCancelled else { return }

            sessionMessages.append((role: "assistant", content: content))
            liveText = content

            // TTS
            state = .speaking
            await playTTS(for: content)

            guard !Task.isCancelled else { return }

            // Auto-resume listening
            liveText = ""
            startListening()

        } catch is CancellationError {
            return
        } catch {
            log.error("Voice send error: \(error)")
            state = .error("Connection error.")
        }
    }

    @MainActor
    private func playTTS(for text: String) async {
        guard let ttsURL = URL(string: "\(serverURL)/api/tts/") else { return }

        var request = URLRequest(url: ttsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
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
            audioPlayer?.delegate = self

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                self.ttsCompletion = { continuation.resume() }
                self.audioPlayer?.play()
            }
        } catch {
            log.error("TTS error: \(error)")
        }
    }

    private var ttsCompletion: (() -> Void)?

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.ttsCompletion?()
            self?.ttsCompletion = nil
        }
    }
}
