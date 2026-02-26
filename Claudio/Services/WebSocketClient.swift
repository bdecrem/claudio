import Foundation
import os

private let log = Logger(subsystem: "com.claudio.app", category: "WebSocket")

/// Thread-safe WebSocket client for OpenClaw Gateway RPC protocol.
actor WebSocketClient {

    // MARK: - Connection State

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case pairingRequired
        case error(String)
    }

    // Callback for state changes — called on MainActor
    var onStateChange: (@MainActor (ConnectionState) -> Void)?
    var onChatEvent: (@MainActor (ChatEvent) -> Void)?
    var onAgentEvent: (@MainActor (AgentEvent) -> Void)?

    private(set) var connectionState: ConnectionState = .disconnected

    // MARK: - Private

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var serverURL: String = ""
    private var authToken: String = ""

    private var pendingRequests: [String: CheckedContinuation<RPCResponse, Error>] = [:]
    private var nextRequestId = 1
    private var tickIntervalMs: Int = 15000
    private var lastTickTime: Date = Date()
    private var keepaliveTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var isIntentionalDisconnect = false

    // MARK: - Public API

    func setCallbacks(
        onStateChange: @escaping @MainActor (ConnectionState) -> Void,
        onChatEvent: @escaping @MainActor (ChatEvent) -> Void,
        onAgentEvent: @escaping @MainActor (AgentEvent) -> Void
    ) {
        self.onStateChange = onStateChange
        self.onChatEvent = onChatEvent
        self.onAgentEvent = onAgentEvent
    }

    func connect(serverURL: String, token: String) {
        self.serverURL = serverURL
        self.authToken = token
        self.isIntentionalDisconnect = false
        self.reconnectAttempt = 0
        Task { await doConnect() }
    }

    func disconnect() {
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        cancelAllPending(error: WebSocketError.disconnected)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        setState(.disconnected)
    }

    /// Send an RPC request and wait for the response
    func send(method: String, params: [String: AnyCodableValue] = [:]) async throws -> RPCResponse {
        guard webSocketTask != nil else {
            throw WebSocketError.notConnected
        }

        let id = generateId()
        let request = RPCRequest(id: id, method: method, params: params)
        let data = try JSONEncoder().encode(request)
        let string = String(data: data, encoding: .utf8)!

        log.info("→ \(method) id=\(id)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            Task {
                do {
                    try await webSocketTask?.send(.string(string))
                } catch {
                    log.error("Send failed: \(error)")
                    if let cont = pendingRequests.removeValue(forKey: id) {
                        cont.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Chat Methods

    func chatHistory(sessionKey: String, limit: Int = 50) async throws -> [HistoryMessage] {
        let params: [String: AnyCodableValue] = [
            "sessionKey": .string(sessionKey),
            "limit": .int(limit)
        ]
        let response = try await send(method: "chat.history", params: params)

        guard response.ok, let payload = response.payload,
              let messagesArray = payload["messages"]?.arrayValue else {
            return []
        }

        return messagesArray.compactMap { HistoryMessage(from: $0) }
    }

    func chatSend(sessionKey: String, message: String, attachments: [[String: String]] = []) async throws -> String? {
        var params: [String: AnyCodableValue] = [
            "sessionKey": .string(sessionKey),
            "message": .string(message),
            "deliver": .bool(false),
            "idempotencyKey": .string(UUID().uuidString)
        ]
        if !attachments.isEmpty {
            let encoded: [AnyCodableValue] = attachments.map { dict in
                .object(dict.mapValues { .string($0) })
            }
            params["attachments"] = .array(encoded)
        }
        let response = try await send(method: "chat.send", params: params)

        guard response.ok else {
            let errMsg = response.error?.message ?? "Unknown error"
            throw WebSocketError.serverError(errMsg)
        }

        return response.payload?["runId"]?.stringValue
    }

    func chatAbort(sessionKey: String) async throws {
        let params: [String: AnyCodableValue] = ["sessionKey": .string(sessionKey)]
        _ = try await send(method: "chat.abort", params: params)
    }

    func agentsList() async throws -> [WSAgent] {
        let response = try await send(method: "agents.list")

        guard response.ok, let payload = response.payload,
              let agentsArray = payload["agents"]?.arrayValue else {
            return []
        }

        return agentsArray.compactMap { WSAgent(from: $0) }
    }

    // MARK: - Device Registration

    func registerApnsToken(_ token: String, bundleId: String) async throws {
        let params: [String: AnyCodableValue] = [
            "token": .string(token),
            "bundleId": .string(bundleId)
        ]
        _ = try await send(method: "device.registerApnsToken", params: params)
    }

    // MARK: - Connection Flow

    private func doConnect() async {
        guard !serverURL.isEmpty else {
            setState(.error("No server URL"))
            return
        }

        setState(.connecting)

        // Build WebSocket URL
        var wsURL = serverURL
        if wsURL.hasPrefix("https://") {
            wsURL = "wss://" + wsURL.dropFirst("https://".count)
        } else if wsURL.hasPrefix("http://") {
            wsURL = "ws://" + wsURL.dropFirst("http://".count)
        } else if !wsURL.hasPrefix("ws://") && !wsURL.hasPrefix("wss://") {
            wsURL = "wss://" + wsURL
        }

        guard let url = URL(string: wsURL) else {
            setState(.error("Invalid server URL"))
            return
        }

        log.info("Connecting to \(wsURL)")

        let session = URLSession(configuration: .default)
        urlSession = session
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        // Start receiving messages
        receiveTask?.cancel()
        receiveTask = Task { await receiveLoop() }
    }

    private func receiveLoop() async {
        while !Task.isCancelled {
            guard let task = webSocketTask else { break }

            do {
                let message = try await task.receive()
                switch message {
                case .string(let text):
                    await handleMessage(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        await handleMessage(text)
                    }
                @unknown default:
                    break
                }
            } catch {
                if !Task.isCancelled && !isIntentionalDisconnect {
                    log.error("Receive error: \(error)")
                    await handleDisconnect()
                }
                break
            }
        }
    }

    private func handleMessage(_ text: String) async {
        guard let data = text.data(using: .utf8) else { return }

        // Try to determine message type
        struct TypePeek: Decodable {
            let type: String
        }

        guard let peek = try? JSONDecoder().decode(TypePeek.self, from: data) else {
            log.warning("Unparseable message: \(text.prefix(100))")
            return
        }

        switch peek.type {
        case "res":
            if let response = try? JSONDecoder().decode(RPCResponse.self, from: data) {
                handleResponse(response)
            }

        case "event":
            if let event = try? JSONDecoder().decode(RPCEvent.self, from: data) {
                await handleEvent(event)
            }

        default:
            log.warning("Unknown message type: \(peek.type)")
        }
    }

    private func handleResponse(_ response: RPCResponse) {
        log.info("← res id=\(response.id) ok=\(response.ok)")

        // Route connect response specially (not through continuations)
        if response.id == connectRequestId {
            handleConnectResponse(response)
            return
        }

        if let continuation = pendingRequests.removeValue(forKey: response.id) {
            continuation.resume(returning: response)
        }
    }

    private func handleEvent(_ event: RPCEvent) async {
        switch event.event {
        case "connect.challenge":
            handleChallenge(event.payload)

        case "tick":
            lastTickTime = Date()

        case "chat":
            if let chatEvent = ChatEvent(from: event.payload) {
                if let handler = onChatEvent {
                    await handler(chatEvent)
                }
            }

        case "agent":
            if let agentEvent = AgentEvent(from: event.payload) {
                if let handler = onAgentEvent {
                    await handler(agentEvent)
                }
            }

        default:
            log.info("Event: \(event.event)")
        }
    }

    /// The connect request ID so we can identify the connect response
    private let connectRequestId = "connect-1"

    private func handleChallenge(_ payload: [String: AnyCodableValue]?) {
        guard let payload,
              let nonce = payload["nonce"]?.stringValue else {
            log.error("Challenge missing nonce")
            setState(.error("Invalid challenge from server"))
            return
        }

        let identity = DeviceIdentity.shared
        let signedAt = Int64(Date().timeIntervalSince1970 * 1000)

        // Use deviceToken if available, otherwise use the gateway auth token
        let token = identity.deviceToken ?? authToken

        guard let signature = identity.signChallenge(nonce: nonce, token: token, signedAt: signedAt) else {
            setState(.error("Failed to sign challenge"))
            return
        }

        let clientObj: [String: AnyCodableValue] = [
            "id": .string("openclaw-ios"),
            "displayName": .string("Claudio"),
            "version": .string("1.0.0"),
            "platform": .string("ios"),
            "mode": .string("ui")
        ]

        let deviceObj: [String: AnyCodableValue] = [
            "id": .string(identity.deviceId),
            "publicKey": .string(identity.publicKeyBase64URL),
            "signature": .string(signature),
            "signedAt": .int(Int(signedAt)),
            "nonce": .string(nonce)
        ]

        let authObj: [String: AnyCodableValue] = [
            "token": .string(token)
        ]

        let params: [String: AnyCodableValue] = [
            "minProtocol": .int(3),
            "maxProtocol": .int(3),
            "client": .object(clientObj),
            "role": .string("operator"),
            "scopes": .array([.string("operator.read"), .string("operator.write")]),
            "caps": .array([.string("tool-events")]),
            "auth": .object(authObj),
            "device": .object(deviceObj)
        ]

        // Send connect request directly (fire-and-forget) to avoid actor deadlock.
        // The response will be handled by handleConnectResponse via handleResponse.
        let request = RPCRequest(id: connectRequestId, method: "connect", params: params)
        guard let data = try? JSONEncoder().encode(request),
              let string = String(data: data, encoding: .utf8) else {
            setState(.error("Failed to encode connect request"))
            return
        }

        log.info("→ connect (challenge signed)")
        Task {
            do {
                try await webSocketTask?.send(.string(string))
            } catch {
                log.error("Failed to send connect: \(error)")
                setState(.error("Connection failed"))
            }
        }
    }

    private func handleConnectResponse(_ response: RPCResponse) {
        if response.ok {
            // Save device token
            if let auth = response.payload?["auth"]?.objectValue,
               let deviceToken = auth["deviceToken"]?.stringValue {
                DeviceIdentity.shared.deviceToken = deviceToken
                log.info("Saved deviceToken")
            }

            // Get tick interval
            if let policy = response.payload?["policy"]?.objectValue,
               let interval = policy["tickIntervalMs"]?.intValue {
                tickIntervalMs = interval
            }

            reconnectAttempt = 0
            lastTickTime = Date()
            setState(.connected)
            startKeepalive()

            log.info("Connected successfully")
        } else {
            let errorCode = response.error?.code ?? ""
            let errorMsg = response.error?.message ?? "Connection failed"

            if errorCode == "PAIRING_REQUIRED" {
                log.warning("Pairing required")
                setState(.pairingRequired)
            } else {
                log.error("Connect failed: \(errorCode) \(errorMsg)")
                setState(.error(errorMsg))
            }
        }
    }

    // MARK: - Keepalive

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }

                let elapsed = Date().timeIntervalSince(lastTickTime)
                let threshold = Double(tickIntervalMs) * 2.0 / 1000.0

                if elapsed > threshold {
                    log.warning("Tick timeout (\(Int(elapsed))s), reconnecting")
                    await handleDisconnect()
                    break
                }
            }
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() async {
        guard !isIntentionalDisconnect else { return }

        keepaliveTask?.cancel()
        receiveTask?.cancel()
        cancelAllPending(error: WebSocketError.disconnected)
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        setState(.disconnected)
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            let baseMs: Double = 800
            let multiplier: Double = 1.7
            let capMs: Double = 15000

            let delayMs = min(baseMs * pow(multiplier, Double(reconnectAttempt)), capMs)
            reconnectAttempt += 1

            log.info("Reconnecting in \(Int(delayMs))ms (attempt \(self.reconnectAttempt))")

            try? await Task.sleep(for: .milliseconds(Int(delayMs)))
            guard !Task.isCancelled && !isIntentionalDisconnect else { return }

            await doConnect()
        }
    }

    // MARK: - Helpers

    private func generateId() -> String {
        let id = "c\(nextRequestId)"
        nextRequestId += 1
        return id
    }

    private func setState(_ state: ConnectionState) {
        connectionState = state
        if let handler = onStateChange {
            Task { @MainActor in handler(state) }
        }
    }

    private func cancelAllPending(error: Error) {
        for (_, continuation) in pendingRequests {
            continuation.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }
}

// MARK: - Errors

enum WebSocketError: LocalizedError {
    case notConnected
    case disconnected
    case serverError(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected to server."
        case .disconnected: return "Disconnected from server."
        case .serverError(let msg): return msg
        case .timeout: return "Request timed out."
        }
    }
}
