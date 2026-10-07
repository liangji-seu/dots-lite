import Foundation

public enum DotsCoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL(String)
    case invalidToken
    case invalidParameter(String)
    case invalidResponse
    case httpStatus(Int, detail: String?)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let message): return message
        case .invalidToken: return "A non-empty device token is required."
        case .invalidParameter(let message): return message
        case .invalidResponse: return "The device returned an invalid response."
        case .httpStatus(let code, let detail):
            return detail.map { "HTTP \(code): \($0)" } ?? "HTTP \(code)"
        }
    }
}

public enum BaseURLValidator {
    public static func validate(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw DotsCoreError.invalidBaseURL("Base URL must use HTTP(S), have no credentials, query, or fragment, and include a host.")
        }
        if let port = components.port, !(1...65535).contains(port) {
            throw DotsCoreError.invalidBaseURL("Base URL has an invalid port.")
        }
        guard scheme == "https" || isPrivateHost(host) else {
            throw DotsCoreError.invalidBaseURL("HTTP is allowed only for localhost or an explicitly private address.")
        }
    }

    public static func validated(_ url: URL) throws -> URL {
        try validate(url)
        return url
    }

    static func isPrivateHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") { return true }
        if host.contains(":") { return isPrivateIPv6(host) }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4,
              host.split(separator: ".").count == 4,
              octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let a = octets[0], b = octets[1]
        return a == 10 || a == 127 || (a == 172 && (16...31).contains(b)) ||
            (a == 192 && b == 168) || (a == 100 && (64...127).contains(b)) ||
            (a == 169 && b == 254)
    }

    private static func isPrivateIPv6(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "::1" || normalized == "0:0:0:0:0:0:0:1" ||
            normalized.hasPrefix("fc") || normalized.hasPrefix("fd") ||
            normalized.hasPrefix("fe8") || normalized.hasPrefix("fe9") ||
            normalized.hasPrefix("fea") || normalized.hasPrefix("feb")
    }
}

public struct DeviceProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var baseURL: URL

    public init(id: UUID = UUID(), name: String, baseURL: URL) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DotsCoreError.invalidParameter("Device name must not be empty.")
        }
        try BaseURLValidator.validate(baseURL)
        self.id = id
        self.name = name
        self.baseURL = baseURL
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decode(URL.self, forKey: .baseURL)
        try BaseURLValidator.validate(baseURL)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DotsCoreError.invalidParameter("Device name must not be empty.")
        }
    }
}

public struct DeviceInfo: Codable, Equatable, Sendable {
    public let apiVersion: Int
    public let instanceID: String
    public let id: String
    public let name: String
    public let hostname: String
    public let status: String
    public let platform: String
    public let version: String
    public let capabilities: [String: Capability]

    public struct Capability: Codable, Equatable, Sendable {
        public let available: Bool
        public init(available: Bool) { self.available = available }
    }

    public init(apiVersion: Int, instanceID: String, id: String, name: String, hostname: String,
                status: String, platform: String, version: String,
                capabilities: [String: Capability]) {
        self.apiVersion = apiVersion; self.instanceID = instanceID; self.id = id; self.name = name
        self.hostname = hostname; self.status = status; self.platform = platform; self.version = version
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey { case apiVersion = "api_version", instanceID = "instance_id", id, name, hostname, status, platform, version, capabilities }
}

public struct Project: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct Agent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let available: Bool
    public let supportsResume: Bool
    public init(id: String, available: Bool, supportsResume: Bool) {
        self.id = id; self.available = available; self.supportsResume = supportsResume
    }
    enum CodingKeys: String, CodingKey { case id, available, supportsResume = "supports_resume" }
}

public enum TaskStatus: Equatable, Hashable, Codable, Sendable {
    case queued, running, completed, failed, cancelled, unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "queued": self = .queued
        case "running": self = .running
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .queued: return "queued"; case .running: return "running"; case .completed: return "completed"
        case .failed: return "failed"; case .cancelled: return "cancelled"; case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws { self.init(rawValue: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

public struct TaskSummary: Codable, Equatable, Identifiable, Sendable {
    public let taskID: String
    public let projectID: String
    public let agentID: String
    public let status: TaskStatus
    public let createdAt: String
    public let startedAt: String?
    public let finishedAt: String?
    public let exitCode: Int?
    public let sessionID: String?
    public let parentTaskID: String?
    public let conversationID: String
    public var id: String { taskID }

    public init(taskID: String, projectID: String, agentID: String, status: TaskStatus, createdAt: String,
                startedAt: String?, finishedAt: String?, exitCode: Int?, sessionID: String?,
                parentTaskID: String?, conversationID: String) {
        self.taskID = taskID; self.projectID = projectID; self.agentID = agentID; self.status = status
        self.createdAt = createdAt; self.startedAt = startedAt; self.finishedAt = finishedAt; self.exitCode = exitCode
        self.sessionID = sessionID; self.parentTaskID = parentTaskID; self.conversationID = conversationID
    }
    enum CodingKeys: String, CodingKey { case taskID = "task_id", projectID = "project_id", agentID = "agent_id", status, createdAt = "created_at", startedAt = "started_at", finishedAt = "finished_at", exitCode = "exit_code", sessionID = "session_id", parentTaskID = "parent_task_id", conversationID = "conversation_id" }
}

public struct TaskSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let taskID: String
    public let projectID: String
    public let agentID: String
    public let prompt: String
    public let status: TaskStatus
    public let createdAt: String
    public let startedAt: String?
    public let finishedAt: String?
    public let exitCode: Int?
    public let output: String
    public let error: String?
    public let outputTruncated: Bool
    public let sessionID: String?
    public let parentTaskID: String?
    public let conversationID: String
    public var id: String { taskID }

    public init(taskID: String, projectID: String, agentID: String, prompt: String, status: TaskStatus,
                createdAt: String, startedAt: String?, finishedAt: String?, exitCode: Int?, output: String,
                error: String?, outputTruncated: Bool, sessionID: String?, parentTaskID: String?, conversationID: String) {
        self.taskID = taskID; self.projectID = projectID; self.agentID = agentID; self.prompt = prompt; self.status = status
        self.createdAt = createdAt; self.startedAt = startedAt; self.finishedAt = finishedAt; self.exitCode = exitCode
        self.output = output; self.error = error; self.outputTruncated = outputTruncated; self.sessionID = sessionID
        self.parentTaskID = parentTaskID; self.conversationID = conversationID
    }
    enum CodingKeys: String, CodingKey { case taskID = "task_id", projectID = "project_id", agentID = "agent_id", prompt, status, createdAt = "created_at", startedAt = "started_at", finishedAt = "finished_at", exitCode = "exit_code", output, error, outputTruncated = "output_truncated", sessionID = "session_id", parentTaskID = "parent_task_id", conversationID = "conversation_id" }
}

public struct TaskPage: Codable, Equatable, Sendable {
    public let items: [TaskSummary]
    public let offset: Int
    public let limit: Int
    public let total: Int
    public init(items: [TaskSummary], offset: Int, limit: Int, total: Int) { self.items = items; self.offset = offset; self.limit = limit; self.total = total }
}

public struct EventLogState: Equatable, Sendable {
    public internal(set) var lastSeq: Int = 0
    public internal(set) var status: TaskStatus?
    public internal(set) var output: String = ""
    public internal(set) var sessionID: String?
    public internal(set) var exitCode: Int?
    public internal(set) var error: String?
    public internal(set) var gapDetected: Bool = false
    public internal(set) var snapshotFallback: Bool = false
    public internal(set) var historyTruncated: Bool = false
    public internal(set) var displayMessage: String?

    public init() {}
}
