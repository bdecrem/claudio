import Foundation
import AVFoundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "VoiceService")

/// Closure that sends messages to the server and returns the assistant response
typealias VoiceSendHandler = (_ messages: [[String: String]]) async throws -> String

/// Closure that plays TTS for a given text
typealias VoiceTTSHandler = (_ text: String) async -> Void

@Observable
final class VoiceService {

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
    private var observationTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?

    // Delegation closures (set by ChatView on start)
    private var sendHandler: VoiceSendHandler?
    private var ttsHandler: VoiceTTSHandler?
    private var agentId = ""
    private var chatHistory: [[String: String]] = []

    // MARK: - Public API

    @MainActor
    func start(
        agentId: String,
        chatHistory: [[String: String]],
        speechRecognizer: SpeechRecognizer,
        sendHandler: @escaping VoiceSendHandler,
        ttsHandler: @escaping VoiceTTSHandler
    ) {
        self.agentId = agentId
        self.chatHistory = chatHistory
        self.speechRecognizer = speechRecognizer
        self.sendHandler = sendHandler
        self.ttsHandler = ttsHandler

        startListening()
    }

    @MainActor
    func stop() {
        sendTask?.cancel()
        sendTask = nil
        observationTask?.cancel()
        observationTask = nil
        if let sr = speechRecognizer, sr.isListening {
            _ = sr.stopListening()
        }
        speechRecognizer = nil
        sendHandler = nil
        ttsHandler = nil
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
        guard let sendHandler else {
            state = .error("Not connected.")
            return
        }

        do {
            let content = try await sendHandler(messages)

            guard !Task.isCancelled else { return }

            sessionMessages.append((role: "assistant", content: content))
            liveText = content

            // TTS
            state = .speaking
            if let ttsHandler {
                await ttsHandler(content)
            }

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
}
