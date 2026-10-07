import Foundation
import DotsCore

struct DeviceRecord: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var baseURL: String
    var instanceID: String?
    var isOnline = false
    var lastError: String?
    init(id: UUID = UUID(), name: String, baseURL: String, instanceID: String? = nil) { self.id = id; self.name = name; self.baseURL = baseURL; self.instanceID = instanceID }
    var coreProfile: DotsCore.DeviceProfile? { guard let url = URL(string: baseURL) else { return nil }; return try? DotsCore.DeviceProfile(id: id, name: name, baseURL: url) }
}

struct DeviceDraft { var name = "Windows"; var baseURL = "http://100.x.x.x:8765"; var token = "" }

extension TaskStatus {
    var title: String { switch self { case .queued: return "排队中"; case .running: return "执行中"; case .completed: return "已完成"; case .failed: return "失败"; case .cancelled: return "已取消"; case .unknown(let value): return value } }
    var isTerminal: Bool { switch self { case .completed, .failed, .cancelled: return true; default: return false } }
}

extension TaskSummary {
    static func from(_ snapshot: TaskSnapshot) -> TaskSummary { TaskSummary(taskID: snapshot.taskID, projectID: snapshot.projectID, agentID: snapshot.agentID, status: snapshot.status, createdAt: snapshot.createdAt, startedAt: snapshot.startedAt, finishedAt: snapshot.finishedAt, exitCode: snapshot.exitCode, sessionID: snapshot.sessionID, parentTaskID: snapshot.parentTaskID, conversationID: snapshot.conversationID) }
}

func bridgeDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    let regular = ISO8601DateFormatter(); regular.formatOptions = [.withInternetDateTime]
    return regular.date(from: value)
}
