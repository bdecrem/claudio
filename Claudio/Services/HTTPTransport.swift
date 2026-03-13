import Foundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "HTTPTransport")

/// Image attachment to send inline via the Responses API.
struct HTTPImageAttachment {
    let data: Data
    let mediaType: String // e.g. "image/jpeg"
}

/// Sends chat messages via POST /v1/responses with SSE streaming.
/// Uses the OpenAI Responses API format which supports inline image input.
final class HTTPTransport: @unchecked Sendable {
    private var activeTask: Task<Void, Never>?

    /// Send a message and stream back deltas.
    /// - `images` contains raw image data to send inline as base64 `input_image` blocks.
    /// - `onDelta` receives the full accumulated text so far (not per-token).
    /// - `onFinished` receives the final complete text and any image URLs from tool-generated media.
    /// - `onError` receives an error description.
    func sendMessage(
        baseURL: String,
        token: String,
        agentId: String,
        messages: [[String: Any]],
        images: [HTTPImageAttachment] = [],
        onDelta: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (String, [String]) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) {
        abort()

        activeTask = Task {
            do {
                try await stream(
                    baseURL: baseURL,
                    token: token,
                    agentId: agentId,
                    messages: messages,
                    images: images,
                    onDelta: onDelta,
                    onFinished: onFinished,
                    onError: onError
                )
            } catch is CancellationError {
                log.info("HTTP stream cancelled")
            } catch {
                log.error("HTTP stream error: \(error)")
                await MainActor.run { onError(error.localizedDescription) }
            }
        }
    }

    func abort() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - Internal

    /// Convert chat-completions-style messages to Responses API `input` items.
    /// Each message becomes `{"type": "message", "role": ..., "content": ...}`.
    /// If the last user message has images, they are appended as `input_image` content parts.
    private func buildInput(messages: [[String: Any]], images: [HTTPImageAttachment]) -> [[String: Any]] {
        var input: [[String: Any]] = []

        for (i, msg) in messages.enumerated() {
            guard let role = msg["role"] as? String else { continue }
            let content = msg["content"] as? String ?? ""
            if content.isEmpty && role != "assistant" { continue }

            let isLastUser = (role == "user") && (i == messages.count - 1 || !messages[(i+1)...].contains(where: { ($0["role"] as? String) == "user" }))

            if isLastUser && !images.isEmpty {
                // Build content array with text + images
                var parts: [[String: Any]] = [
                    ["type": "input_text", "text": content]
                ]
                for img in images {
                    parts.append([
                        "type": "input_image",
                        "source": [
                            "type": "base64",
                            "media_type": img.mediaType,
                            "data": img.data.base64EncodedString()
                        ] as [String: Any]
                    ])
                }
                input.append([
                    "type": "message",
                    "role": role,
                    "content": parts
                ])
            } else {
                input.append([
                    "type": "message",
                    "role": role,
                    "content": content
                ])
            }
        }

        return input
    }

    private func stream(
        baseURL: String,
        token: String,
        agentId: String,
        messages: [[String: Any]],
        images: [HTTPImageAttachment],
        onDelta: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (String, [String]) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws {
        let base = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
            .replacingOccurrences(of: "/v1/chat/completions", with: "")
            .replacingOccurrences(of: "/v1/responses", with: "")
        let urlString = base + "/v1/responses"

        guard let url = URL(string: urlString) else {
            await MainActor.run { onError("Invalid server URL") }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("agent:\(agentId):main", forHTTPHeaderField: "x-openclaw-session-key")
        if let host = url.host?.lowercased(), host.contains("ngrok") {
            request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        }

        let input = buildInput(messages: messages, images: images)
        let body: [String: Any] = [
            "model": "default",
            "stream": true,
            "user": "agent:\(agentId):main",
            "input": input
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let bodySize = bodyData.count
        log.info("POST \(urlString) token=\(token.prefix(8))... bodySize=\(bodySize) images=\(images.count)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            log.error("HTTP: response is not HTTPURLResponse")
            await MainActor.run { onError("Invalid response from server") }
            return
        }

        log.info("HTTP: status=\(httpResponse.statusCode)")

        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line + "\n"
                if errorBody.count > 1000 { break }
            }
            log.error("HTTP error \(httpResponse.statusCode): \(errorBody.prefix(500))")
            let statusCode = httpResponse.statusCode
            await MainActor.run { onError("Server returned HTTP \(statusCode): \(errorBody.prefix(200))") }
            return
        }

        // Parse Responses API SSE events
        var accumulated = ""
        var lineCount = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            lineCount += 1

            if lineCount <= 10 {
                log.info("SSE[\(lineCount)]: \(line.prefix(200))")
            }

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let eventType = json["type"] as? String else {
                continue
            }

            switch eventType {
            case "response.output_text.delta":
                if let delta = json["delta"] as? String, !delta.isEmpty {
                    accumulated += delta
                    let text = accumulated
                    await MainActor.run { onDelta(text) }
                }

            case "response.completed":
                // Extract final text from the completed response
                if let resp = json["response"] as? [String: Any],
                   let output = resp["output"] as? [[String: Any]] {
                    for item in output {
                        if let content = item["content"] as? [[String: Any]] {
                            for part in content {
                                if (part["type"] as? String) == "output_text",
                                   let text = part["text"] as? String {
                                    accumulated = text
                                }
                            }
                        }
                    }
                }
                log.info("HTTP: response.completed after \(lineCount) lines")

            case "response.failed":
                log.error("HTTP: response.failed")
                break

            default:
                break
            }
        }

        let finalText = accumulated
        log.info("HTTP stream complete: \(finalText.count) chars, \(lineCount) lines")

        // Fetch media attachments generated by server-side tool calls
        let sessionKey = "agent:\(agentId):main"
        let imageURLs = await fetchMediaAttachments(baseURL: base, token: token, sessionKey: sessionKey)
        log.info("HTTP: got \(imageURLs.count) media attachment(s)")

        await MainActor.run { onFinished(finalText, imageURLs) }
    }

    /// Fetch image URLs captured by the claudio-media plugin's hooks.
    private func fetchMediaAttachments(baseURL: String, token: String, sessionKey: String) async -> [String] {
        let base = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
            .replacingOccurrences(of: "/v1/chat/completions", with: "")
            .replacingOccurrences(of: "/v1/responses", with: "")
        guard var components = URLComponents(string: "\(base)/media/attachments") else { return [] }
        components.queryItems = [URLQueryItem(name: "session", value: sessionKey)]
        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let host = url.host?.lowercased(), host.contains("ngrok") {
            request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attachments = json["attachments"] as? [[String: Any]] else {
                return []
            }
            return attachments.compactMap { $0["url"] as? String }
        } catch {
            log.warning("Failed to fetch media attachments: \(error)")
            return []
        }
    }
}
