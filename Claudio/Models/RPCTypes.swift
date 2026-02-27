import Foundation

// MARK: - Wire Protocol

/// Outgoing request
struct RPCRequest: Encodable {
    let type = "req"
    let id: String
    let method: String
    let params: [String: AnyCodableValue]
}

/// Incoming response
struct RPCResponse: Decodable {
    let type: String
    let id: String
    let ok: Bool
    let payload: [String: AnyCodableValue]?
    let error: RPCError?
}

struct RPCError: Decodable {
    let code: String?
    let message: String?
}

/// Incoming event
struct RPCEvent: Decodable {
    let type: String
    let event: String
    let payload: [String: AnyCodableValue]?
}

// MARK: - Chat Event

struct ChatEvent {
    let sessionKey: String
    let runId: String
    let state: ChatEventState
    let text: String?
    let audioAttachments: [AudioAttachment]
    let errorMessage: String?

    struct AudioAttachment {
        let mimeType: String?
        let base64Data: String?
        let url: String?
        let mediaPath: String?
    }

    enum ChatEventState: String {
        case delta
        case final_ = "final"
        case aborted
        case error
    }

    init?(from payload: [String: AnyCodableValue]?) {
        guard let payload else { return nil }

        self.sessionKey = payload["sessionKey"]?.stringValue ?? ""
        self.runId = payload["runId"]?.stringValue ?? ""

        guard let stateStr = payload["state"]?.stringValue,
              let state = ChatEventState(rawValue: stateStr) else { return nil }
        self.state = state

        var extractedText: [String] = []
        var extractedAudio: [AudioAttachment] = []

        if let message = payload["message"]?.objectValue {
            if let content = message["content"]?.arrayValue {
                for block in content {
                    guard let obj = block.objectValue else { continue }
                    if let text = obj["text"]?.stringValue, !text.isEmpty {
                        extractedText.append(text)
                    }
                    if let audio = Self.extractAudio(from: obj) {
                        extractedAudio.append(audio)
                    }
                }
            }
            if let attachments = message["attachments"]?.arrayValue {
                for attachment in attachments {
                    guard let obj = attachment.objectValue else { continue }
                    if let audio = Self.extractAudio(from: obj) {
                        extractedAudio.append(audio)
                    }
                }
            }
        }

        if let attachments = payload["attachments"]?.arrayValue {
            for attachment in attachments {
                guard let obj = attachment.objectValue else { continue }
                if let audio = Self.extractAudio(from: obj) {
                    extractedAudio.append(audio)
                }
            }
        }

        let joinedText = extractedText.joined()
        self.text = joinedText.isEmpty ? nil : joinedText
        self.audioAttachments = extractedAudio

        self.errorMessage = payload["errorMessage"]?.stringValue
    }

    private static func extractAudio(from object: [String: AnyCodableValue]) -> AudioAttachment? {
        let type = object["type"]?.stringValue?.lowercased()
        let mimeType = object["mimeType"]?.stringValue ?? object["mime_type"]?.stringValue
        let text = object["text"]?.stringValue
        let isMediaText = (text?.hasPrefix("MEDIA:") == true) && (text?.lowercased().contains(".mp3") == true)

        let isLikelyAudio = (type == "audio")
            || (mimeType?.lowercased().hasPrefix("audio/") == true)
            || object["audio"]?.objectValue != nil
            || isMediaText

        guard isLikelyAudio else { return nil }

        let directData = object["data"]?.stringValue
            ?? object["base64"]?.stringValue
            ?? object["content"]?.stringValue
        let directURL = object["url"]?.stringValue
        let directPath = object["path"]?.stringValue
            ?? object["mediaPath"]?.stringValue

        var nestedData: String?
        var nestedURL: String?
        var nestedPath: String?
        if let nested = object["audio"]?.objectValue {
            nestedData = nested["data"]?.stringValue
                ?? nested["base64"]?.stringValue
                ?? nested["content"]?.stringValue
            nestedURL = nested["url"]?.stringValue
            nestedPath = nested["path"]?.stringValue
                ?? nested["mediaPath"]?.stringValue
        }

        let mediaPathFromText: String? = {
            if let txt = text, txt.hasPrefix("MEDIA:") {
                return String(txt.dropFirst("MEDIA:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }()

        let base64Data = directData ?? nestedData
        let url = directURL ?? nestedURL
        let mediaPath = directPath ?? nestedPath ?? mediaPathFromText

        if base64Data == nil, url == nil, mediaPath == nil {
            return nil
        }

        return AudioAttachment(
            mimeType: mimeType ?? object["audio"]?.objectValue?["mimeType"]?.stringValue,
            base64Data: base64Data,
            url: url,
            mediaPath: mediaPath
        )
    }
}

// MARK: - Agent Event

struct AgentEvent {
    let sessionKey: String
    let runId: String
    let stream: String       // "tool", "lifecycle", "assistant"
    let phase: String         // "start", "update", "result", "end"
    let callId: String?
    let toolName: String?
    let args: [String: String]?
    let meta: String?         // tool result summary (e.g. the command that ran)
    let isError: Bool

    init?(from payload: [String: AnyCodableValue]?) {
        guard let payload,
              let stream = payload["stream"]?.stringValue,
              let data = payload["data"]?.objectValue,
              let phase = data["phase"]?.stringValue else { return nil }

        self.sessionKey = payload["sessionKey"]?.stringValue ?? ""
        self.runId = payload["runId"]?.stringValue ?? ""
        self.stream = stream
        self.phase = phase
        self.callId = data["toolCallId"]?.stringValue
        self.toolName = data["name"]?.stringValue
        self.isError = data["isError"]?.boolValue ?? false
        self.meta = data["meta"]?.stringValue

        // Parse args — flatten to [String: String] for display
        if let argsObj = data["args"]?.objectValue {
            var flat: [String: String] = [:]
            for (k, v) in argsObj {
                switch v {
                case .string(let s): flat[k] = s
                case .int(let i): flat[k] = String(i)
                case .double(let d): flat[k] = String(d)
                case .bool(let b): flat[k] = String(b)
                default: flat[k] = "..."
                }
            }
            self.args = flat
        } else {
            self.args = nil
        }
    }
}

// MARK: - Connect

struct ConnectClient: Encodable {
    let id = "openclaw-ios"
    let displayName = "Claudio"
    let version = "1.0.0"
    let platform = "ios"
    let mode = "ui"
}

// MARK: - History Message

struct HistoryMessage {
    let role: String
    let content: String
    let timestamp: Date?

    init?(from value: AnyCodableValue) {
        guard let obj = value.objectValue,
              let role = obj["role"]?.stringValue else { return nil }

        // content can be a plain string or an array of content blocks
        if let contentStr = obj["content"]?.stringValue {
            self.content = contentStr
        } else if let contentArr = obj["content"]?.arrayValue {
            // Extract text from content blocks: [{type:"text", text:"..."}, ...]
            let texts = contentArr.compactMap { block -> String? in
                guard let blockObj = block.objectValue,
                      blockObj["type"]?.stringValue == "text",
                      let text = blockObj["text"]?.stringValue else { return nil }
                return text
            }
            let joined = texts.joined()
            // Skip messages with no text content (e.g. only thinking blocks)
            guard !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            self.content = joined.trimmingCharacters(in: .newlines)
        } else {
            return nil
        }

        self.role = role
        if let ts = obj["timestamp"]?.doubleValue {
            self.timestamp = Date(timeIntervalSince1970: ts / 1000.0)
        } else {
            self.timestamp = nil
        }
    }
}

// MARK: - Agent from WebSocket

struct WSAgent {
    let id: String
    let name: String
    let emoji: String?
    let color: String?

    init?(from value: AnyCodableValue) {
        guard let obj = value.objectValue,
              let id = obj["id"]?.stringValue else { return nil }
        self.id = id
        self.name = obj["name"]?.stringValue ?? id
        self.emoji = obj["emoji"]?.stringValue
        self.color = obj["color"]?.stringValue
    }
}

// MARK: - AnyCodableValue

/// Lightweight type-erased JSON value for flexible RPC payloads
enum AnyCodableValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AnyCodableValue])
    case array([AnyCodableValue])
    case null

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }

    var doubleValue: Double? {
        if case .double(let d) = self { return d }
        if case .int(let i) = self { return Double(i) }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: AnyCodableValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [AnyCodableValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([AnyCodableValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: AnyCodableValue].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - Helper to build params dicts

extension Dictionary where Key == String, Value == AnyCodableValue {
    static func params(_ pairs: (String, AnyCodableValue)...) -> [String: AnyCodableValue] {
        Dictionary(uniqueKeysWithValues: pairs)
    }
}
