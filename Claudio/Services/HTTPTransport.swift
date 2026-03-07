import Foundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "HTTPTransport")

/// HTTP+SSE transport for OpenClaw chat completions API.
/// Stateless — each message is a fresh POST request with full conversation history.
actor HTTPTransport {

    // MARK: - Types

    struct ChatDelta {
        let content: String?
        let isFinished: Bool
    }

    // MARK: - Properties

    private var serverURL: String = ""
    private var authToken: String = ""
    private var currentTask: Task<Void, Never>?

    // MARK: - Public API

    func configure(serverURL: String, token: String) {
        self.serverURL = serverURL
        self.authToken = token
    }

    /// Send a message and stream back deltas via the callback.
    /// The messages array should contain the full conversation history including the new user message.
    func sendMessage(
        messages: [[String: String]],
        agentId: String,
        onDelta: @MainActor @escaping (ChatDelta) -> Void
    ) async throws {
        let httpURL = makeHTTPURL(from: serverURL)
        guard let url = URL(string: httpURL) else {
            throw HTTPTransportError.invalidURL(httpURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        }

        // Skip ngrok browser warning
        if let host = url.host?.lowercased(), host.contains("ngrok") {
            request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        }

        let sessionKey = "agent:\(agentId):main"
        let body: [String: Any] = [
            "model": "default",
            "stream": true,
            "user": sessionKey,
            "messages": messages
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        log.info("POST \(httpURL) agent=\(agentId) messages=\(messages.count)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPTransportError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Try to read error body
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            throw HTTPTransportError.httpError(httpResponse.statusCode, errorBody)
        }

        // Parse SSE stream
        var accumulatedContent = ""

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }

            let jsonString = String(line.dropFirst(6))

            if jsonString == "[DONE]" {
                await onDelta(ChatDelta(content: accumulatedContent, isFinished: true))
                break
            }

            guard let data = jsonString.data(using: .utf8) else { continue }

            do {
                let chunk = try JSONDecoder().decode(SSEChunk.self, from: data)
                if let delta = chunk.choices.first?.delta {
                    if let content = delta.content {
                        accumulatedContent += content
                        await onDelta(ChatDelta(content: accumulatedContent, isFinished: false))
                    }
                    if chunk.choices.first?.finish_reason == "stop" {
                        await onDelta(ChatDelta(content: accumulatedContent, isFinished: true))
                        break
                    }
                }
            } catch {
                log.warning("Failed to parse SSE chunk: \(error) json=\(jsonString.prefix(200))")
            }
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    // MARK: - URL Conversion

    private func makeHTTPURL(from serverURL: String) -> String {
        var base = serverURL
        if base.hasPrefix("wss://") {
            base = "https://" + base.dropFirst("wss://".count)
        } else if base.hasPrefix("ws://") {
            base = "http://" + base.dropFirst("ws://".count)
        }
        // Remove trailing slash
        while base.hasSuffix("/") {
            base = String(base.dropLast())
        }
        return base + "/v1/chat/completions"
    }

    // MARK: - SSE JSON Models

    private struct SSEChunk: Decodable {
        let choices: [Choice]

        struct Choice: Decodable {
            let delta: Delta?
            let finish_reason: String?
        }

        struct Delta: Decodable {
            let role: String?
            let content: String?
        }
    }
}

// MARK: - Errors

enum HTTPTransportError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid server URL: \(url)"
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code, let body):
            if body.isEmpty {
                return "Server returned HTTP \(code)"
            }
            return "Server returned HTTP \(code): \(body.prefix(200))"
        }
    }
}
