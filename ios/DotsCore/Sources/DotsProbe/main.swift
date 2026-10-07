import DotsCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main
struct DotsProbe {
    static func main() async {
        guard let rawBase = ProcessInfo.processInfo.environment["DOTS_PROBE_BASE_URL"],
              let token = ProcessInfo.processInfo.environment["DOTS_PROBE_TOKEN"],
              let baseURL = URL(string: rawBase) else {
            print("SKIP missing DOTS_PROBE_BASE_URL or DOTS_PROBE_TOKEN")
            return
        }
        var stage = "profile"
        do {
            let profile = try DeviceProfile(name: "probe", baseURL: baseURL)
            let client = try DotsAPIClient(profile: profile, token: token)
            stage = "device"; _ = try await client.fetchDevice()
            stage = "projects";
            let projects = try await client.fetchProjects()
            stage = "agents";
            _ = try await client.fetchAgents()
            guard let project = projects.first(where: { $0.id == "dots-lite" }) else { throw DotsCoreError.invalidParameter("dots-lite project was not returned by device") }
            stage = "create"; let task = try await client.createTask(projectID: project.id, prompt: "probe", agentID: "fake")
            stage = "ws-first";
            let firstStream = try await receiveStream(client: client, taskID: task.taskID, after: 0)
            stage = "snapshot";
            let final = try await client.fetchTask(id: task.taskID)
            guard final.taskID == task.taskID else { throw DotsCoreError.invalidResponse }
            stage = "ws-replay"; let replay = try await receiveStream(client: client, taskID: task.taskID, after: max(0, firstStream.lastSeq - 2))
            guard replay.output.contains("stream") else { throw DotsCoreError.invalidResponse }
            stage = "ws-final-close"; _ = try await receiveStream(client: client, taskID: task.taskID, after: firstStream.lastSeq)
            stage = "resume";
            let resumed = try await client.resumeTask(id: task.taskID, prompt: "probe resume", agentID: "fake")
            guard resumed.taskID != task.taskID, resumed.conversationID == task.conversationID, resumed.sessionID == final.sessionID else { throw DotsCoreError.invalidResponse }
            stage = "cancel"; let waiting = try await client.createTask(projectID: project.id, prompt: "CANCEL_WAIT", agentID: "fake")
            _ = try await client.cancelTask(id: waiting.taskID)
            var cancelled = false
            for _ in 0..<30 {
                let value = try await client.fetchTask(id: waiting.taskID)
                if value.status == .cancelled { cancelled = true; break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard cancelled else { throw DotsCoreError.invalidResponse }
            let wrong = try? DotsAPIClient(profile: profile, token: token + "-wrong")
            var wrongRejected = false
            stage = "wrong-token"; if let wrong {
                do { _ = try await wrong.fetchDevice() }
                catch DotsCoreError.httpStatus(401, _) { wrongRejected = true }
                catch { throw error }
            }
            guard wrongRejected else { throw DotsCoreError.invalidResponse }
            print("PASS device projects agents create ws(seq=\(firstStream.lastSeq)) replay(seq=\(replay.lastSeq)) snapshot resume(conversation) cancel wrong-token")
        } catch {
            print("FAIL stage=\(stage) \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func receiveStream(client: DotsAPIClient, taskID: String, after: Int) async throws -> (lastSeq: Int, output: String) {
        let request = try client.webSocketRequest(taskID: taskID, after: after)
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        var reducer = EventLogReducer()
        for _ in 0..<256 {
            let message: URLSessionWebSocketTask.Message
            do { message = try await socket.receive() }
            catch {
                if reducer.state.status == .completed || reducer.state.status == .failed || reducer.state.status == .cancelled { break }
                let snapshot = try await client.fetchTask(id: taskID)
                guard snapshot.status == .completed || snapshot.status == .failed || snapshot.status == .cancelled else { throw error }
                return (max(after, reducer.state.lastSeq), snapshot.output)
            }
            let data: Data
            switch message { case .data(let value): data = value; case .string(let value): data = Data(value.utf8) @unknown default: continue }
            let event = try JSONDecoder().decode(StreamEvent.self, from: data)
            _ = reducer.apply(event)
            if reducer.state.status == .completed || reducer.state.status == .failed || reducer.state.status == .cancelled { break }
        }
        return (reducer.state.lastSeq, reducer.state.output)
    }
}
