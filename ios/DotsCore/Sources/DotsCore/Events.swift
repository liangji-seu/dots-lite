import Foundation

public struct StatusEvent: Equatable, Sendable {
    public let taskID: String; public let seq: Int; public let timestamp: String; public let status: TaskStatus; public let exitCode: Int?; public let error: String?
}
public struct OutputEvent: Equatable, Sendable {
    public let taskID: String; public let seq: Int; public let timestamp: String; public let stream: String; public let text: String
}
public struct SessionEvent: Equatable, Sendable {
    public let taskID: String; public let seq: Int; public let timestamp: String; public let sessionID: String
}
public struct GapEvent: Equatable, Sendable {
    public let taskID: String; public let timestamp: String; public let after: Int; public let oldest: Int
}
public struct HeartbeatEvent: Equatable, Sendable { public let taskID: String; public let timestamp: String }
public struct TruncatedEvent: Equatable, Sendable {
    public let taskID: String; public let seq: Int; public let timestamp: String; public let originalType: String; public let originalBytes: Int
}
public struct ProviderEvent: Equatable, Sendable {
    public let taskID: String; public let seq: Int; public let timestamp: String; public let eventType: String; public let payload: JSONValue?
}
public struct UnknownStreamEvent: Equatable, Sendable {
    public let type: String; public let taskID: String?; public let seq: Int?; public let timestamp: String?; public let raw: JSONValue
}

public indirect enum JSONValue: Codable, Equatable, Sendable {
    case null, boolean(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .boolean(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .null: try c.encodeNil(); case .boolean(let v): try c.encode(v); case .number(let v): try c.encode(v); case .string(let v): try c.encode(v); case .array(let v): try c.encode(v); case .object(let v): try c.encode(v) }
    }
}

public enum StreamEvent: Codable, Equatable, Sendable {
    case status(StatusEvent)
    case output(OutputEvent)
    case session(SessionEvent)
    case gap(GapEvent)
    case heartbeat(HeartbeatEvent)
    case truncated(TruncatedEvent)
    case providerEvent(ProviderEvent)
    case unknown(UnknownStreamEvent)

    enum Keys: String, CodingKey { case type, taskID = "task_id", seq, timestamp, status, exitCode = "exit_code", error, stream, text, sessionID = "session_id", after, oldest, originalType = "original_type", originalBytes = "original_bytes", eventType = "event_type", payload }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        let taskID = try c.decodeIfPresent(String.self, forKey: .taskID)
        let timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        switch type {
        case "status":
            self = .status(StatusEvent(taskID: try Self.require(taskID, "task_id"), seq: try Self.require(c.decodeIfPresent(Int.self, forKey: .seq), "seq"), timestamp: try Self.require(timestamp, "timestamp"), status: try c.decode(TaskStatus.self, forKey: .status), exitCode: try c.decodeIfPresent(Int.self, forKey: .exitCode), error: try c.decodeIfPresent(String.self, forKey: .error)))
        case "output":
            self = .output(OutputEvent(taskID: try Self.require(taskID, "task_id"), seq: try Self.require(c.decodeIfPresent(Int.self, forKey: .seq), "seq"), timestamp: try Self.require(timestamp, "timestamp"), stream: try c.decode(String.self, forKey: .stream), text: try c.decode(String.self, forKey: .text)))
        case "session":
            self = .session(SessionEvent(taskID: try Self.require(taskID, "task_id"), seq: try Self.require(c.decodeIfPresent(Int.self, forKey: .seq), "seq"), timestamp: try Self.require(timestamp, "timestamp"), sessionID: try c.decode(String.self, forKey: .sessionID)))
        case "gap":
            self = .gap(GapEvent(taskID: try Self.require(taskID, "task_id"), timestamp: try Self.require(timestamp, "timestamp"), after: try c.decode(Int.self, forKey: .after), oldest: try c.decode(Int.self, forKey: .oldest)))
        case "heartbeat":
            self = .heartbeat(HeartbeatEvent(taskID: try Self.require(taskID, "task_id"), timestamp: try Self.require(timestamp, "timestamp")))
        case "truncated":
            self = .truncated(TruncatedEvent(taskID: try Self.require(taskID, "task_id"), seq: try Self.require(c.decodeIfPresent(Int.self, forKey: .seq), "seq"), timestamp: try Self.require(timestamp, "timestamp"), originalType: try c.decode(String.self, forKey: .originalType), originalBytes: try c.decode(Int.self, forKey: .originalBytes)))
        case "provider_event":
            self = .providerEvent(ProviderEvent(taskID: try Self.require(taskID, "task_id"), seq: try Self.require(c.decodeIfPresent(Int.self, forKey: .seq), "seq"), timestamp: try Self.require(timestamp, "timestamp"), eventType: try c.decodeIfPresent(String.self, forKey: .eventType) ?? "provider_event", payload: try c.decodeIfPresent(JSONValue.self, forKey: .payload)))
        default:
            let raw = try decoder.singleValueContainer().decode(JSONValue.self)
            self = .unknown(UnknownStreamEvent(type: type, taskID: taskID, seq: try c.decodeIfPresent(Int.self, forKey: .seq), timestamp: timestamp, raw: raw))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .status(let e): try c.encode("status", forKey: .type); try encodeCommon(e.taskID, e.seq, e.timestamp, &c); try c.encode(e.status, forKey: .status); try c.encodeIfPresent(e.exitCode, forKey: .exitCode); try c.encodeIfPresent(e.error, forKey: .error)
        case .output(let e): try c.encode("output", forKey: .type); try encodeCommon(e.taskID, e.seq, e.timestamp, &c); try c.encode(e.stream, forKey: .stream); try c.encode(e.text, forKey: .text)
        case .session(let e): try c.encode("session", forKey: .type); try encodeCommon(e.taskID, e.seq, e.timestamp, &c); try c.encode(e.sessionID, forKey: .sessionID)
        case .gap(let e): try c.encode("gap", forKey: .type); try c.encode(e.taskID, forKey: .taskID); try c.encode(e.timestamp, forKey: .timestamp); try c.encode(e.after, forKey: .after); try c.encode(e.oldest, forKey: .oldest)
        case .heartbeat(let e): try c.encode("heartbeat", forKey: .type); try c.encode(e.taskID, forKey: .taskID); try c.encode(e.timestamp, forKey: .timestamp)
        case .truncated(let e): try c.encode("truncated", forKey: .type); try encodeCommon(e.taskID, e.seq, e.timestamp, &c); try c.encode(e.originalType, forKey: .originalType); try c.encode(e.originalBytes, forKey: .originalBytes)
        case .providerEvent(let e): try c.encode("provider_event", forKey: .type); try encodeCommon(e.taskID, e.seq, e.timestamp, &c); try c.encode(e.eventType, forKey: .eventType); try c.encodeIfPresent(e.payload, forKey: .payload)
        case .unknown(let e): try c.encode(e.type, forKey: .type); try c.encodeIfPresent(e.taskID, forKey: .taskID); try c.encodeIfPresent(e.seq, forKey: .seq); try c.encodeIfPresent(e.timestamp, forKey: .timestamp)
        }
    }

    private static func require<T>(_ value: T?, _ field: String) throws -> T { guard let value else { throw DotsCoreError.invalidResponse }; return value }
    private func encodeCommon(_ taskID: String, _ seq: Int, _ timestamp: String, _ c: inout KeyedEncodingContainer<Keys>) throws { try c.encode(taskID, forKey: .taskID); try c.encode(seq, forKey: .seq); try c.encode(timestamp, forKey: .timestamp) }
}

public struct EventLogReducer: Sendable {
    public static let maxOutputCharacters = 262_144
    public private(set) var state: EventLogState
    private var suppressOutputReplay = false

    public init(state: EventLogState = EventLogState()) { self.state = state }

    @discardableResult
    public mutating func apply(_ event: StreamEvent) -> Bool {
        if case .gap = event {
            state.gapDetected = true; state.snapshotFallback = true; state.historyTruncated = true
            suppressOutputReplay = true
            state.displayMessage = "部分早期日志已截断"
            return true
        }
        let seq: Int?
        switch event { case .status(let e): seq = e.seq; case .output(let e): seq = e.seq; case .session(let e): seq = e.seq; case .truncated(let e): seq = e.seq; case .providerEvent(let e): seq = e.seq; case .unknown(let e): seq = e.seq; case .heartbeat, .gap: seq = nil }
        if let seq {
            guard seq > state.lastSeq else { return false }
            state.lastSeq = seq
        }
        switch event {
        case .status(let e): state.status = e.status; state.exitCode = e.exitCode; state.error = e.error
        case .output(let e): if !suppressOutputReplay { appendOutput(e.text) }
        case .session(let e): state.sessionID = e.sessionID
        case .truncated: state.historyTruncated = true; state.displayMessage = "日志中有事件被截断"
        case .providerEvent, .unknown, .heartbeat, .gap: break
        }
        return true
    }

    /// Replaces the stream output with the REST tail after a gap. REST has no sequence
    /// watermark, so snapshot fallback remains active and output replay stays suppressed.
    public mutating func applySnapshot(_ snapshot: TaskSnapshot) {
        state.output = String(snapshot.output.suffix(Self.maxOutputCharacters)); state.status = snapshot.status; state.sessionID = snapshot.sessionID
        state.exitCode = snapshot.exitCode; state.error = snapshot.error; state.gapDetected = true
        state.snapshotFallback = true; state.historyTruncated = true
        state.displayMessage = "部分早期日志已截断"
        suppressOutputReplay = true
    }

    private mutating func appendOutput(_ text: String) {
        state.output += text
        guard state.output.count > Self.maxOutputCharacters else { return }
        state.output = String(state.output.suffix(Self.maxOutputCharacters))
        state.historyTruncated = true
        if !state.gapDetected { state.displayMessage = "本地日志仅保留最近 \(Self.maxOutputCharacters) 个字符" }
    }
}
