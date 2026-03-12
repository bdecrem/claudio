import Foundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "HTTPTransport")

/// Sends chat messages via POST /v1/chat/completions with SSE streaming.
/// Alternative to WebSocket transport for servers with the HTTP endpoint enabled.
final class HTTPTransport: @unchecked Sendable {
    private var activeTask: Task<Void, Never>?

    /// Send a message and stream back deltas.
    /// - `onDelta` receives the full accumulated text so far (not per-token).
    /// - `onFinished` receives the final complete text.
    /// - `onError` receives an error description.
    func sendMessage(
        baseURL: String,
        token: String,
        agentId: String,
        messages: [[String: String]],
        onDelta: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (String) -> Void,
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

    private func stream(
        baseURL: String,
        token: String,
        agentId: String,
        messages: [[String: String]],
        onDelta: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (String) -> Void,
        onError: @escaping @MainActor (String) -> Void
    ) async throws {
        var urlString = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        if !urlString.hasSuffix("/v1/chat/completions") {
            urlString += "/v1/chat/completions"
        }
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

        let body: [String: Any] = [
            "model": "default",
            "stream": true,
            "user": "agent:\(agentId):main",
            "messages": messages
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bodyData

        let bodyPreview = String(data: bodyData, encoding: .utf8)?.prefix(500) ?? "<nil>"
        log.info("POST \(urlString) token=\(token.prefix(8))... body=\(bodyPreview)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            log.error("HTTP: response is not HTTPURLResponse")
            await MainActor.run { onError("Invalid response from server") }
            return
        }

        log.info("HTTP: status=\(httpResponse.statusCode) contentType=\(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "nil")")

        guard (200...299).contains(httpResponse.statusCode) else {
            // Read error body for diagnostics
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

        var accumulated = ""
        var lineCount = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            lineCount += 1

            // Log first 10 SSE lines for debugging
            if lineCount <= 10 {
                log.info("HTTP SSE[\(lineCount)]: \(line.prefix(200))")
            }

            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst(6))

            if payload == "[DONE]" {
                log.info("HTTP: got [DONE] after \(lineCount) lines")
                break
            }

            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let choice = choices.first else {
                if lineCount <= 10 {
                    log.warning("HTTP: failed to parse SSE payload: \(payload.prefix(200))")
                }
                continue
            }

            // Check for finish_reason
            if let finishReason = choice["finish_reason"] as? String, !finishReason.isEmpty {
                log.info("HTTP: finish_reason=\(finishReason) after \(lineCount) lines")
                break
            }

            // Extract delta content
            if let delta = choice["delta"] as? [String: Any],
               let content = delta["content"] as? String, !content.isEmpty {
                accumulated += content
                let text = accumulated
                await MainActor.run { onDelta(text) }
            }
        }

        let finalText = accumulated
        log.info("HTTP stream complete: \(finalText.count) chars, \(lineCount) lines total")
        await MainActor.run { onFinished(finalText) }
    }
}
