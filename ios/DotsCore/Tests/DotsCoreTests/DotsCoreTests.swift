import XCTest
@testable import DotsCore

final class DotsCoreTests: XCTestCase {
    func testJSONModelsAndTaskConversationIdentity() throws {
        let json = #"{"task_id":"t1","project_id":"dots-lite","agent_id":"fake","prompt":"hello","status":"future_state","created_at":"2026-10-07T00:00:00Z","started_at":null,"finished_at":null,"exit_code":null,"output":"out","error":null,"output_truncated":false,"session_id":"s1","parent_task_id":"p1","conversation_id":"c1"}"#.data(using: .utf8)!
        let task = try JSONDecoder().decode(TaskSnapshot.self, from: json)
        XCTAssertEqual(task.status, .unknown("future_state"))
        XCTAssertEqual(task.taskID, "t1")
        XCTAssertEqual(task.parentTaskID, "p1")
        XCTAssertEqual(task.conversationID, "c1")
        let encoded = try JSONEncoder().encode(task)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("conversation_id"))
    }

    func testDeviceProfileRejectsCredentialsQueryFragmentAndPublicHTTP() throws {
        XCTAssertThrowsError(try DeviceProfile(name: "x", baseURL: URL(string: "http://user:pass@192.168.1.2:8765")!))
        XCTAssertThrowsError(try DeviceProfile(name: "x", baseURL: URL(string: "http://192.168.1.2:8765/api?token=secret")!))
        XCTAssertThrowsError(try DeviceProfile(name: "x", baseURL: URL(string: "http://8.8.8.8:8765")!))
        XCTAssertNoThrow(try DeviceProfile(name: "x", baseURL: URL(string: "http://100.64.1.2:8765/bridge")!))
        XCTAssertNoThrow(try DeviceProfile(name: "x", baseURL: URL(string: "https://example.com/bridge")!))
    }

    func testWebSocketRequestUsesPathAndAuthorizationHeader() throws {
        let factory = try WebSocketRequestFactory(baseURL: URL(string: "http://100.64.1.2:8765/bridge")!, token: "secret")
        let request = try factory.makeRequest(taskID: "t/one", after: 7)
        XCTAssertEqual(request.url?.scheme, "ws")
        XCTAssertEqual(request.url?.path, "/bridge/api/tasks/t/one/stream")
        XCTAssertTrue(request.url?.absoluteString.contains("t%2Fone") ?? false)
        XCTAssertEqual(request.url?.query, "after=7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
        XCTAssertFalse(request.url?.absoluteString.contains("secret") ?? true)
    }

    func testReducerDedupeUnknownSeqAndUnknownStatus() throws {
        var reducer = EventLogReducer()
        let decoder = JSONDecoder()
        let output = try decoder.decode(StreamEvent.self, from: Data(#"{"type":"output","task_id":"t","seq":1,"timestamp":"now","stream":"stdout","text":"a"}"#.utf8))
        XCTAssertTrue(reducer.apply(output)); XCTAssertFalse(reducer.apply(output))
        let unknown = try decoder.decode(StreamEvent.self, from: Data(#"{"type":"future","task_id":"t","seq":4,"timestamp":"now","value":1}"#.utf8))
        XCTAssertTrue(reducer.apply(unknown)); XCTAssertEqual(reducer.state.lastSeq, 4)
        let futureStatus = try decoder.decode(StreamEvent.self, from: Data(#"{"type":"status","task_id":"t","seq":5,"timestamp":"now","status":"paused"}"#.utf8))
        XCTAssertTrue(reducer.apply(futureStatus)); XCTAssertEqual(reducer.state.status, .unknown("paused")); XCTAssertFalse(reducer.state.status?.rawValue == "completed")
    }

    func testGapSnapshotReplacesOutputWithoutReplayDuplication() throws {
        var reducer = EventLogReducer()
        let decoder = JSONDecoder()
        _ = reducer.apply(try decoder.decode(StreamEvent.self, from: Data(#"{"type":"output","task_id":"t","seq":1,"timestamp":"now","stream":"stdout","text":"old"}"#.utf8)))
        _ = reducer.apply(try decoder.decode(StreamEvent.self, from: Data(#"{"type":"gap","task_id":"t","timestamp":"now","after":1,"oldest":40}"#.utf8)))
        XCTAssertTrue(reducer.state.snapshotFallback)
        let snapshot = TaskSnapshot(taskID: "t", projectID: "p", agentID: "a", prompt: "", status: .running, createdAt: "", startedAt: nil, finishedAt: nil, exitCode: nil, output: "snapshot", error: nil, outputTruncated: true, sessionID: nil, parentTaskID: nil, conversationID: "c")
        reducer.applySnapshot(snapshot)
        XCTAssertEqual(reducer.state.output, "snapshot")
        let replay = try decoder.decode(StreamEvent.self, from: Data(#"{"type":"output","task_id":"t","seq":40,"timestamp":"now","stream":"stdout","text":"snapshot"}"#.utf8))
        XCTAssertTrue(reducer.apply(replay)); XCTAssertEqual(reducer.state.output, "snapshot")
        XCTAssertTrue(reducer.state.snapshotFallback)
        let live = try decoder.decode(StreamEvent.self, from: Data(#"{"type":"output","task_id":"t","seq":41,"timestamp":"now","stream":"stdout","text":" live"}"#.utf8))
        _ = reducer.apply(live); XCTAssertEqual(reducer.state.output, "snapshot")
    }

    func testReducerBoundsOutputAndKeepsSequence() {
        var reducer = EventLogReducer()
        XCTAssertTrue(reducer.apply(.output(OutputEvent(taskID: "t", seq: 1, timestamp: "now", stream: "stdout", text: String(repeating: "x", count: EventLogReducer.maxOutputCharacters + 17)))))
        XCTAssertEqual(reducer.state.output.count, EventLogReducer.maxOutputCharacters)
        XCTAssertEqual(reducer.state.lastSeq, 1)
        XCTAssertTrue(reducer.state.historyTruncated)
        XCTAssertFalse(reducer.state.snapshotFallback)
    }
}
