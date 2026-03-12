import Foundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "HTTPTransport")

/// Sends chat messages via POST /v1/chat/completions with SSE streaming.
/// Alternative to WebSocket transport for servers with the HTTP endpoint enabled.
final class HTTPTransport: @unchecked Sendable {
    private var activeTask: Task<Void, Never>?

    /// Send a message and stream back deltas.
    /// - `onDelta` receives the full accumulated text so far (not per-token).
    /// - `onFinished` receives the final complete text and any image URLs from tool-generated media.
    /// - `onError` receives an error description.
    func sendMessage(
        baseURL: String,
        token: String,
        agentId: String,
        messages: [[String: Any]],
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

    /// Upload an image and return its public URL
    func uploadImage(baseURL: String, token: String, imageData: Data, contentType: String) async throws -> String {
        var urlString = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        if urlString.hasSuffix("/v1/chat/completions") {
            urlString = String(urlString.dropLast("/v1/chat/completions".count))
        }
        urlString += "/media/upload"

        guard let url = URL(string: urlString) else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let host = url.host?.lowercased(), host.contains("ngrok") {
            request.setValue("true", forHTTPHeaderField: "ngrok-skip-browser-warning")
        }

        let dataURL = "data:\(contentType);base64,\(imageData.base64EncodedString())"
        let body = ["image": dataURL]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        log.info("Uploading image to \(urlString)")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "Upload failed: HTTP \(status)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String else {
            throw URLError(.cannotParseResponse, userInfo: [NSLocalizedDescriptionKey: "No path in upload response"])
        }

        log.info("Upload complete: \(path)")
        return path
    }

    // MARK: - Internal

    private func stream(
        baseURL: String,
        token: String,
        agentId: String,
        messages: [[String: Any]],
        onDelta: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor (String, [String]) -> Void,
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

        // Fetch media attachments generated by server-side tool calls.
        // The SSE stream only contains the assistant's text — tool outputs
        // (like generated images) are captured by the claudio-media plugin
        // and served via GET /media/attachments.
        let sessionKey = "agent:\(agentId):openai-user:agent:\(agentId):main"
        let imageURLs = await fetchMediaAttachments(baseURL: baseURL, token: token, sessionKey: sessionKey)

        await MainActor.run { onFinished(finalText, imageURLs) }
    }

    /// Fetch image URLs captured by the claudio-media plugin's after_tool_call hook.
    private func fetchMediaAttachments(baseURL: String, token: String, sessionKey: String) async -> [String] {
        let base = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
            .replacingOccurrences(of: "/v1/chat/completions", with: "")
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
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else { return [] }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let attachments = json["attachments"] as? [[String: Any]] else { return [] }
            let urls = attachments.compactMap { $0["url"] as? String }
            if !urls.isEmpty {
                log.info("Fetched \(urls.count) media attachment(s) from server")
            }
            return urls
        } catch {
            log.warning("Failed to fetch media attachments: \(error)")
            return []
        }
    }
}
