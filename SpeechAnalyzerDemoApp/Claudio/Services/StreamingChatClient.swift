import Foundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "StreamingChat")

/// SSE event from the streaming chat endpoint
enum ChatStreamEvent {
    case start(messageId: String)
    case delta(content: String)
    case done(messageId: String, fullContent: String)
}

/// Actor that handles OpenAI-compatible SSE streaming via /v1/chat/completions
/// Falls back to non-streaming /api/chat/agent if streaming fails
actor StreamingChatClient {

    func sendStreaming(
        serverURL: String,
        token: String,
        agentId: String,
        messages: [[String: String]]
    ) -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let didStream = try await self.attemptStreaming(
                        serverURL: serverURL,
                        token: token,
                        agentId: agentId,
                        messages: messages,
                        continuation: continuation
                    )
                    if !didStream {
                        try await self.fallbackNonStreaming(
                            serverURL: serverURL,
                            token: token,
                            agentId: agentId,
                            messages: messages,
                            continuation: continuation
                        )
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Collect the full streaming response as a single string (for voice mode)
    func sendAndCollect(
        serverURL: String,
        token: String,
        agentId: String,
        messages: [[String: String]]
    ) async throws -> String {
        var result = ""
        for try await event in sendStreaming(
            serverURL: serverURL,
            token: token,
            agentId: agentId,
            messages: messages
        ) {
            switch event {
            case .delta(let content):
                result += content
            case .done(_, let fullContent):
                return fullContent
            case .start:
                break
            }
        }
        return result
    }

    // MARK: - Streaming via /v1/chat/completions (OpenAI-compatible SSE)

    private func attemptStreaming(
        serverURL: String,
        token: String,
        agentId: String,
        messages: [[String: String]],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws -> Bool {
        guard let url = URL(string: "\(serverURL)/v1/chat/completions") else {
            throw StreamingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if !agentId.isEmpty {
            request.setValue(agentId, forHTTPHeaderField: "x-openclaw-agent-id")
        }

        var body: [String: Any] = [
            "messages": messages,
            "stream": true
        ]
        if !agentId.isEmpty {
            body["model"] = "openclaw:\(agentId)"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        log.info("Streaming POST \(url) agent=\(agentId)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamingError.invalidResponse
        }

        // 404 means endpoint doesn't exist — fall back to legacy
        if httpResponse.statusCode == 404 {
            log.info("v1/chat/completions returned 404, falling back to legacy endpoint")
            return false
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw StreamingError.authFailed
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw StreamingError.serverError(httpResponse.statusCode)
        }

        // Parse OpenAI-compatible SSE
        // Format: lines of "data: {json}" separated by blank lines, ending with "data: [DONE]"
        var fullContent = ""
        var messageId = ""
        var started = false

        for try await line in bytes.lines {
            guard line.hasPrefix("data: ") else { continue }

            let payload = String(line.dropFirst(6))

            // Stream terminator
            if payload == "[DONE]" {
                continuation.yield(.done(messageId: messageId, fullContent: fullContent))
                break
            }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                continue
            }

            // Extract message ID from first chunk
            if !started {
                messageId = json["id"] as? String ?? ""
                continuation.yield(.start(messageId: messageId))
                started = true
            }

            // Extract delta content: choices[0].delta.content
            if let choices = json["choices"] as? [[String: Any]],
               let delta = choices.first?["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                fullContent += content
                continuation.yield(.delta(content: content))
            }
        }

        // If stream ended without [DONE] but we got content, finalize
        if started && fullContent.isEmpty == false {
            // Already yielded done above if [DONE] was received
        }

        continuation.finish()
        return true
    }

    // MARK: - Fallback: non-streaming /api/chat/agent

    private func fallbackNonStreaming(
        serverURL: String,
        token: String,
        agentId: String,
        messages: [[String: String]],
        continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        guard let url = URL(string: "\(serverURL)/api/chat/agent") else {
            throw StreamingError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        var body: [String: Any] = ["messages": messages]
        if !agentId.isEmpty {
            body["agent"] = agentId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        log.info("Fallback POST \(url)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamingError.invalidResponse
        }

        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw StreamingError.authFailed
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw StreamingError.serverError(httpResponse.statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw StreamingError.unexpectedFormat
        }

        continuation.yield(.start(messageId: ""))
        continuation.yield(.delta(content: content))
        continuation.yield(.done(messageId: "", fullContent: content))
        continuation.finish()
    }
}

enum StreamingError: LocalizedError {
    case invalidURL
    case invalidResponse
    case authFailed
    case serverError(Int)
    case unexpectedFormat

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid server address."
        case .invalidResponse: return "Invalid response."
        case .authFailed: return "Authentication failed. Check your token."
        case .serverError(let code): return "Server error (\(code))."
        case .unexpectedFormat: return "Unexpected response format."
        }
    }
}
