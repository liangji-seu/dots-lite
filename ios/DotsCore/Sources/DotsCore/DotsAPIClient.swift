import Foundation

public struct WebSocketRequestFactory: Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: URL, token: String) throws {
        try BaseURLValidator.validate(baseURL)
        guard !token.isEmpty else { throw DotsCoreError.invalidToken }
        self.baseURL = baseURL; self.token = token
    }

    public func makeRequest(taskID: String, after: Int) throws -> URLRequest {
        guard !taskID.isEmpty, after >= 0 else { throw DotsCoreError.invalidParameter("Task ID and cursor are invalid.") }
        var components = try websocketComponents()
        components.percentEncodedPath = Self.joinedPath(components.percentEncodedPath, "/api/tasks/\(Self.escapePathSegment(taskID))/stream")
        components.queryItems = [URLQueryItem(name: "after", value: String(after))]
        guard let url = components.url else { throw DotsCoreError.invalidBaseURL("Unable to construct WebSocket URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func websocketComponents() throws -> URLComponents {
        guard var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw DotsCoreError.invalidBaseURL("Unable to read base URL.") }
        c.scheme = c.scheme?.lowercased() == "https" ? "wss" : "ws"
        c.query = nil; c.fragment = nil; c.user = nil; c.password = nil
        return c
    }

    static func joinedPath(_ base: String, _ suffix: String) -> String {
        let left = base == "/" ? "" : base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/" + ([left, suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))].filter { !$0.isEmpty }.joined(separator: "/"))
    }

    static func escapePathSegment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? value }
}

public final class DotsAPIClient: @unchecked Sendable {
    public let profile: DeviceProfile
    private let token: String
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(profile: DeviceProfile, token: String, session: URLSession = .shared) throws {
        guard !token.isEmpty else { throw DotsCoreError.invalidToken }
        self.profile = profile; self.token = token; self.session = session
        self.encoder = JSONEncoder(); self.decoder = JSONDecoder()
    }

    public func fetchDevice() async throws -> DeviceInfo { try await send(path: "/api/device", method: "GET", body: Optional<EmptyBody>.none) }
    public func fetchProjects() async throws -> [Project] { try await send(path: "/api/projects", method: "GET", body: Optional<EmptyBody>.none) }
    public func fetchAgents() async throws -> [Agent] { try await send(path: "/api/agents", method: "GET", body: Optional<EmptyBody>.none) }

    public func listTasks(offset: Int = 0, limit: Int = 50) async throws -> TaskPage {
        guard offset >= 0, limit > 0 else { throw DotsCoreError.invalidParameter("Task page offset and limit must be positive.") }
        return try await send(path: "/api/tasks", method: "GET", query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: String(limit))], body: Optional<EmptyBody>.none)
    }

    public func fetchTask(id: String) async throws -> TaskSnapshot { try await send(path: "/api/tasks/\(WebSocketRequestFactory.escapePathSegment(id))", method: "GET", body: Optional<EmptyBody>.none) }

    public func createTask(projectID: String, prompt: String, agentID: String = "codex") async throws -> TaskSnapshot {
        guard !projectID.isEmpty, !prompt.isEmpty, prompt.count <= 32000, !agentID.isEmpty else { throw DotsCoreError.invalidParameter("Task creation fields are invalid.") }
        return try await send(path: "/api/tasks", method: "POST", body: CreateTaskRequest(projectID: projectID, prompt: prompt, agentID: agentID))
    }

    public func cancelTask(id: String) async throws -> TaskSnapshot {
        try await send(path: "/api/tasks/\(WebSocketRequestFactory.escapePathSegment(id))/cancel", method: "POST", body: Optional<EmptyBody>.none)
    }

    public func resumeTask(id: String, prompt: String, agentID: String? = nil) async throws -> TaskSnapshot {
        guard !id.isEmpty, !prompt.isEmpty, prompt.count <= 32000 else { throw DotsCoreError.invalidParameter("Resume fields are invalid.") }
        return try await send(path: "/api/tasks/\(WebSocketRequestFactory.escapePathSegment(id))/messages", method: "POST", body: FollowupRequest(prompt: prompt, agentID: agentID))
    }

    public func webSocketRequest(taskID: String, after: Int) throws -> URLRequest { try WebSocketRequestFactory(baseURL: profile.baseURL, token: token).makeRequest(taskID: taskID, after: after) }

    private struct EmptyBody: Encodable {}
    private struct CreateTaskRequest: Encodable { let projectID: String; let prompt: String; let agentID: String; enum CodingKeys: String, CodingKey { case projectID = "project_id", prompt, agentID = "agent_id" } }
    private struct FollowupRequest: Encodable { let prompt: String; let agentID: String?; enum CodingKeys: String, CodingKey { case prompt; case agentID = "agent_id" } }

    private func send<Response: Decodable, Body: Encodable>(path: String, method: String, query: [URLQueryItem] = [], body: Body?) async throws -> Response {
        guard var components = URLComponents(url: profile.baseURL, resolvingAgainstBaseURL: false) else { throw DotsCoreError.invalidBaseURL("Unable to read base URL.") }
        components.percentEncodedPath = WebSocketRequestFactory.joinedPath(components.percentEncodedPath, path)
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw DotsCoreError.invalidBaseURL("Unable to construct API URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DotsCoreError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw DotsCoreError.httpStatus(http.statusCode, detail: Self.errorDetail(from: data, decoder: decoder)) }
        do { return try decoder.decode(Response.self, from: data) } catch { throw DotsCoreError.invalidResponse }
    }

    private static func errorDetail(from data: Data, decoder: JSONDecoder) -> String? {
        struct Detail: Decodable { let detail: String? }
        return (try? decoder.decode(Detail.self, from: data))?.detail
    }
}
