import Foundation
import SwiftUI
import DotsCore

@MainActor
final class AppState: ObservableObject {
    private let localOutputCap = 262_144
    @Published private(set) var profiles: [DeviceRecord] = []
    @Published var selectedDeviceID: UUID?
    @Published var selectedProjectID: String?
    @Published var selectedAgentID = "codex"
    @Published private(set) var projects: [Project] = []
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var tasks: [TaskSummary] = []
    @Published private(set) var snapshots: [String: TaskSnapshot] = [:]
    @Published private(set) var logStates: [String: EventLogState] = [:]
    @Published var banner: String?
    @Published var isRefreshing = false
    @Published var isSubmitting = false
    @Published private(set) var pendingReviewDeviceIDs: Set<UUID> = []

    private let defaults = UserDefaults.standard
    private let profilesKey = "dotslite.device-profiles"
    private var clients: [UUID: DotsAPIClient] = [:]
    private struct SocketHandle { let id: UUID; let task: URLSessionWebSocketTask; let generation: Int }
    private var sockets: [String: SocketHandle] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    private var reducers: [String: EventLogReducer] = [:]
    private var provisional: Set<String> = []
    private var fallbackKeys: Set<String> = []
    private var pollingTasks: [String: Task<Void, Never>] = [:]
    private var pollingIDs: [String: UUID] = [:]
    private var attempts: [String: Int] = [:]
    private var generation = 0
    private var foreground = true
    private var refreshOperationID: UUID?
    private var submissionOperationID: UUID?

    init() {
        if let data = defaults.data(forKey: profilesKey), let value = try? JSONDecoder().decode([DeviceRecord].self, from: data) { profiles = value }
        selectedDeviceID = profiles.first?.id
    }

    var selectedProfile: DeviceRecord? { profiles.first(where: { $0.id == selectedDeviceID }) }
    var requiresSubmissionReview: Bool { selectedDeviceID.map { pendingReviewDeviceIDs.contains($0) } ?? false }
    func token(for profile: DeviceRecord) -> String { KeychainStore.read(deviceID: profile.id.uuidString) ?? "" }

    func selectDevice(_ id: UUID) {
        guard selectedDeviceID != id else { return }
        invalidateConnections(); invalidateOperations(); generation += 1; selectedDeviceID = id; clearDeviceData(); if pendingReviewDeviceIDs.contains(id) { banner = "提交结果未知，请核对任务列表后确认" }
    }

    func saveProfile(_ record: DeviceRecord, token: String) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DotsCoreError.invalidToken }
        guard record.coreProfile != nil else { throw DotsCoreError.invalidBaseURL("设备地址无效") }
        try KeychainStore.save(token, deviceID: record.id.uuidString)
        if let index = profiles.firstIndex(where: { $0.id == record.id }) { profiles[index] = record } else { profiles.append(record) }
        persistProfiles(); invalidateConnections(); invalidateOperations(); generation += 1; selectedDeviceID = record.id; clearDeviceData(); clients[record.id] = nil
    }

    func deleteProfile(_ record: DeviceRecord) {
        invalidateConnections(); invalidateOperations(); generation += 1; KeychainStore.delete(deviceID: record.id.uuidString); profiles.removeAll { $0.id == record.id }; clients[record.id] = nil
        if selectedDeviceID == record.id { selectedDeviceID = profiles.first?.id }; persistProfiles(); clearDeviceData()
    }

    private func persistProfiles() { if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: profilesKey) } }
    private func client(for record: DeviceRecord) throws -> DotsAPIClient {
        guard let profile = record.coreProfile else { throw DotsCoreError.invalidBaseURL("设备地址无效") }
        let token = token(for: record); guard !token.isEmpty else { throw DotsCoreError.invalidToken }
        if let existing = clients[record.id] { return existing }
        let value = try DotsAPIClient(profile: profile, token: token); clients[record.id] = value; return value
    }

    func refreshSelectedDevice() async {
        guard !isRefreshing, let record = selectedProfile else { return }
        let startedGeneration = generation; let operationID = UUID(); refreshOperationID = operationID; isRefreshing = true
        defer { if refreshOperationID == operationID { isRefreshing = false; refreshOperationID = nil } }
        var activeRecord = record; var activeGeneration = startedGeneration
        do {
            let api = try client(for: record); let info = try await api.fetchDevice()
            guard isCurrent(record, startedGeneration) else { return }
            if let old = record.instanceID, old != info.instanceID { invalidateConnections(); generation += 1; activeGeneration = generation; clearDeviceData(); banner = "设备已重启，旧任务日志已清除" }
            activeRecord.instanceID = info.instanceID
            updateProfile(record.id) { $0.instanceID = info.instanceID; $0.isOnline = true; $0.lastError = nil }
            async let projectsValue = api.fetchProjects(); async let agentsValue = api.fetchAgents()
            let loadedProjects = try await projectsValue; let loadedAgents = try await agentsValue
            guard isCurrent(activeRecord, activeGeneration) else { return }
            projects = loadedProjects; agents = loadedAgents
            selectedProjectID = projects.contains(where: { $0.id == selectedProjectID }) ? selectedProjectID : projects.first?.id
            if !agents.contains(where: { $0.id == selectedAgentID && $0.available }) { selectedAgentID = agents.first(where: { $0.available })?.id ?? "codex" }
            await refreshTasks(api, record: activeRecord, generation: activeGeneration)
        } catch { guard isCurrent(activeRecord, activeGeneration) else { return }; updateProfile(record.id) { $0.isOnline = false; $0.lastError = friendly(error) }; banner = friendly(error) }
    }

    private func refreshTasks(_ api: DotsAPIClient, record: DeviceRecord, generation value: Int) async {
        do {
            var all: [TaskSummary] = []; var offset = 0
            while true { let page = try await api.listTasks(offset: offset, limit: 50); guard isCurrent(record, value) else { return }; all += page.items; offset += page.items.count; if page.items.isEmpty || offset >= page.total { break } }
            tasks = all
        } catch { if isCurrent(record, value) { banner = friendly(error) } }
    }
    func refreshTasks() async { guard let record = selectedProfile else { return }; let value = generation; do { try await refreshTasks(client(for: record), record: record, generation: value) } catch { if isCurrent(record, value) { banner = friendly(error) } } }

    @discardableResult
    func createTask(prompt: String) async -> Bool {
        guard !requiresSubmissionReview, !isSubmitting, let record = selectedProfile, record.isOnline, let project = selectedProjectID, !project.isEmpty, prompt.count <= 32000, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, agents.contains(where: { $0.id == selectedAgentID && $0.available }) else { return false }
        let valueGeneration = generation; let operationID = UUID(); submissionOperationID = operationID; isSubmitting = true
        defer { if submissionOperationID == operationID { isSubmitting = false; submissionOperationID = nil } }
        pendingReviewDeviceIDs.insert(record.id)
        do { let value = try await client(for: record).createTask(projectID: project, prompt: prompt, agentID: selectedAgentID); pendingReviewDeviceIDs.remove(record.id); guard isCurrent(record, valueGeneration) else { return false }; add(value, record: record); startStreaming(value.taskID, record: record); return true }
        catch { guard isCurrent(record, valueGeneration) else { return false }; await submissionFailed(error, record: record, generation: valueGeneration, operationID: operationID); return false }
    }

    private func submissionFailed(_ error: Error, record: DeviceRecord, generation value: Int, operationID: UUID) async {
        if isTransport(error) { pendingReviewDeviceIDs.insert(record.id); guard submissionOperationID == operationID, isCurrent(record, value) else { return }; banner = "提交结果未知，请刷新任务列表并确认后再继续"; await refreshTasks() }
        else { pendingReviewDeviceIDs.remove(record.id); if submissionOperationID == operationID, isCurrent(record, value) { banner = friendly(error) } }
    }
    func acknowledgeSubmissionCheck() { if let id = selectedDeviceID { pendingReviewDeviceIDs.remove(id) }; banner = nil }

    func cancel(_ task: TaskSummary) async { guard let record = selectedProfile else { return }; let valueGeneration = generation; do { let value = try await client(for: record).cancelTask(id: task.taskID); guard isCurrent(record, valueGeneration) else { return }; update(value, record: record); if value.status.isTerminal { Task { _ = await snapshot(task.taskID, forceRefresh: true, record: record, expectedGeneration: valueGeneration); guard isCurrent(record, valueGeneration) else { return }; stopStreaming(for: task.taskID) } } } catch { if isCurrent(record, valueGeneration) { banner = friendly(error) } } }
    @discardableResult
    func resume(_ task: TaskSnapshot, prompt: String) async -> Bool {
        guard !requiresSubmissionReview, !isSubmitting, canResume(task), let record = selectedProfile, record.isOnline, prompt.count <= 32000, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let valueGeneration = generation; let operationID = UUID(); submissionOperationID = operationID; isSubmitting = true
        defer { if submissionOperationID == operationID { isSubmitting = false; submissionOperationID = nil } }
        pendingReviewDeviceIDs.insert(record.id)
        do { let value = try await client(for: record).resumeTask(id: task.taskID, prompt: prompt); pendingReviewDeviceIDs.remove(record.id); guard isCurrent(record, valueGeneration) else { return false }; add(value, record: record); startStreaming(value.taskID, record: record); return true }
        catch { guard isCurrent(record, valueGeneration) else { return false }; await submissionFailed(error, record: record, generation: valueGeneration, operationID: operationID); return false }
    }

    func canResume(_ task: TaskSnapshot) -> Bool { task.status.isTerminal && task.sessionID != nil && agents.contains(where: { $0.id == task.agentID && $0.available && $0.supportsResume }) }

    func snapshot(_ taskID: String, forceRefresh: Bool = false, record expectedRecord: DeviceRecord? = nil, expectedGeneration: Int? = nil) async -> TaskSnapshot? {
        guard let record = expectedRecord ?? selectedProfile else { return nil }; let valueGeneration = expectedGeneration ?? generation; let key = cacheKey(taskID, record: record)
        guard isCurrent(record, valueGeneration) else { return nil }
        if !forceRefresh, let cached = snapshots[key] { return cached }
        do { let value = try await client(for: record).fetchTask(id: taskID); guard isCurrent(record, valueGeneration) else { return nil }; update(value, record: record); if var reducer = reducers[key], fallbackKeys.contains(key) { reducer.applySnapshot(value); reducers[key] = reducer; publish(key) }; return value }
        catch { if isCurrent(record, valueGeneration) { banner = friendly(error) }; return nil }
    }

    func currentSnapshot(_ taskID: String) -> TaskSnapshot? { guard let record = selectedProfile else { return nil }; return snapshots[cacheKey(taskID, record: record)] }
    func currentLogState(_ taskID: String) -> EventLogState? { guard let record = selectedProfile else { return nil }; return logStates(for: cacheKey(taskID, record: record)) }
    func output(_ taskID: String) -> String { guard let record = selectedProfile else { return "" }; let key = cacheKey(taskID, record: record); let source = provisional.contains(key) ? (snapshots[key]?.output ?? "") : (reducers[key]?.state.output ?? snapshots[key]?.output ?? ""); return String(source.suffix(localOutputCap)) }
    func isLocallyTruncated(_ taskID: String) -> Bool { guard let record = selectedProfile else { return false }; let key = cacheKey(taskID, record: record); let source = provisional.contains(key) ? (snapshots[key]?.output ?? "") : (reducers[key]?.state.output ?? snapshots[key]?.output ?? ""); return source.count > localOutputCap }

    func startStreaming(_ taskID: String, record: DeviceRecord? = nil) {
        guard foreground, let record = record ?? selectedProfile, let profileInstance = record.instanceID else { return }
        let value = generation; guard isCurrent(record, value) else { return }; let key = cacheKey(taskID, record: record, instanceID: profileInstance); let cursor = reducers[key]?.state.lastSeq ?? 0
        do {
            let request = try client(for: record).webSocketRequest(taskID: taskID, after: cursor); let socket = URLSession.shared.webSocketTask(with: request); let id = UUID()
            sockets[taskID]?.task.cancel(); sockets[taskID] = SocketHandle(id: id, task: socket, generation: value)
            if reducers[key] == nil { reducers[key] = EventLogReducer(); provisional.insert(key); publish(key) }
            socket.resume(); listen(socket, taskID: taskID, record: record, instanceID: profileInstance, socketID: id, generation: value)
        } catch { banner = friendly(error) }
    }

    private func listen(_ socket: URLSessionWebSocketTask, taskID: String, record: DeviceRecord, instanceID: String, socketID: UUID, generation value: Int) {
        socket.receive { [weak self] result in Task { @MainActor [weak self] in
            guard let self, let handle = self.sockets[taskID], handle.id == socketID, handle.generation == value, self.generation == value, self.foreground else { return }
            switch result {
            case .success(let message):
                let data: Data? = { if case .string(let text) = message { return text.data(using: .utf8) }; if case .data(let data) = message { return data }; return nil }()
                if let data, let event = try? JSONDecoder().decode(StreamEvent.self, from: data) { self.apply(event, taskID: taskID, record: record, instanceID: instanceID, generation: value) }
                self.listen(socket, taskID: taskID, record: record, instanceID: instanceID, socketID: socketID, generation: value)
            case .failure: self.handleDisconnect(taskID: taskID, record: record, socketID: socketID, generation: value)
            }
        } }
    }

    private func handleDisconnect(taskID: String, record: DeviceRecord, socketID: UUID, generation value: Int) {
        guard foreground, generation == value, sockets[taskID]?.id == socketID else { return }
        if let status = tasks.first(where: { $0.taskID == taskID })?.status, status.isTerminal { Task { let snapshotValue = await snapshot(taskID, forceRefresh: true, record: record, expectedGeneration: value); guard snapshotValue?.status.isTerminal == true, isCurrent(record, value) else { return }; stopPolling(cacheKey(taskID, record: record, instanceID: record.instanceID ?? "")); stopStreaming(for: taskID) }; return }
        scheduleReconnect(taskID, record: record, instanceID: record.instanceID ?? "", generation: value)
    }

    private func scheduleReconnect(_ taskID: String, record: DeviceRecord, instanceID: String, generation value: Int) {
        guard (attempts[cacheKey(taskID, record: record, instanceID: instanceID)] ?? 0) < 5 else { banner = "实时连接多次失败，正在用任务快照确认状态"; Task { let snapshotValue = await snapshot(taskID, forceRefresh: true, record: record, expectedGeneration: value); guard let snapshotValue, snapshotValue.status.isTerminal, isCurrent(record, value) else { return }; stopStreaming(for: taskID) }; return }
        let key = cacheKey(taskID, record: record, instanceID: instanceID); let attempt = (attempts[key] ?? 0) + 1; attempts[key] = attempt; let delay = UInt64(min(30, 1 << (attempt - 1))) * 1_000_000_000
        reconnectTasks[taskID]?.cancel(); reconnectTasks[taskID] = Task { [weak self] in try? await Task.sleep(nanoseconds: delay); guard !Task.isCancelled else { return }; await MainActor.run { guard let self, self.foreground, self.generation == value, self.sockets[taskID] == nil || self.sockets[taskID]?.generation == value else { return }; self.startStreaming(taskID, record: record) } }
    }

    private func apply(_ event: StreamEvent, taskID: String, record: DeviceRecord, instanceID: String, generation value: Int) {
        let key = cacheKey(taskID, record: record, instanceID: instanceID); var reducer = reducers[key] ?? EventLogReducer(); let changed = reducer.apply(event); if changed { reducers[key] = reducer; provisional.remove(key); publish(key) }
        switch event {
        case .gap(let gap): fallbackKeys.insert(key); banner = "部分早期日志已截断，正在用设备快照刷新"; beginPolling(taskID, record: record, instanceID: instanceID, generation: value, after: gap.after)
        case .status(let status): guard status.taskID == taskID else { return }; updateStatus(status.taskID, status.status, record: record); if status.status.isTerminal { Task { let snapshotValue = await snapshot(taskID, forceRefresh: true, record: record, expectedGeneration: value); guard snapshotValue?.status.isTerminal == true, isCurrent(record, value) else { return }; fallbackKeys.remove(key); stopPolling(key); stopStreaming(for: taskID) } }
        case .output, .session, .truncated, .providerEvent: break
        case .heartbeat, .unknown: break
        }
        attempts[key] = 0
    }

    private func beginPolling(_ taskID: String, record: DeviceRecord, instanceID: String, generation value: Int, after: Int) {
        let key = cacheKey(taskID, record: record, instanceID: instanceID); guard pollingTasks[key] == nil else { return }
        let pollID = UUID(); pollingIDs[key] = pollID
        pollingTasks[key] = Task { [weak self] in await self?.pollSnapshot(taskID, record: record, instanceID: instanceID, generation: value, after: after); await MainActor.run { guard let self, self.pollingIDs[key] == pollID else { return }; self.pollingTasks[key] = nil; self.pollingIDs[key] = nil } }
    }

    private func pollSnapshot(_ taskID: String, record: DeviceRecord, instanceID: String, generation value: Int, after: Int) async {
        let key = cacheKey(taskID, record: record, instanceID: instanceID); guard fallbackKeys.contains(key) else { return }
        while !Task.isCancelled, foreground, generation == value, fallbackKeys.contains(key) {
            let snapshotValue = await snapshot(taskID, forceRefresh: true, record: record, expectedGeneration: value)
            if snapshotValue?.status.isTerminal == true { guard isCurrent(record, value) else { break }; fallbackKeys.remove(key); stopPolling(key); stopStreaming(for: taskID); break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func updateStatus(_ id: String, _ status: TaskStatus, record: DeviceRecord) { guard let index = tasks.firstIndex(where: { $0.taskID == id }) else { return }; let old = tasks[index]; tasks[index] = TaskSummary(taskID: old.taskID, projectID: old.projectID, agentID: old.agentID, status: status, createdAt: old.createdAt, startedAt: old.startedAt, finishedAt: old.finishedAt, exitCode: old.exitCode, sessionID: old.sessionID, parentTaskID: old.parentTaskID, conversationID: old.conversationID) }
    private func add(_ value: TaskSnapshot, record: DeviceRecord) { let key = cacheKey(value.taskID, record: record); snapshots[key] = value; tasks.append(.from(value)) }
    private func update(_ value: TaskSnapshot, record: DeviceRecord) { let key = cacheKey(value.taskID, record: record); snapshots[key] = value; if let index = tasks.firstIndex(where: { $0.taskID == value.taskID }) { let old = tasks[index]; tasks[index] = TaskSummary(taskID: old.taskID, projectID: old.projectID, agentID: old.agentID, status: value.status, createdAt: old.createdAt, startedAt: old.startedAt, finishedAt: old.finishedAt, exitCode: value.exitCode, sessionID: value.sessionID, parentTaskID: old.parentTaskID, conversationID: old.conversationID) } else { tasks.append(.from(value)) } }
    private func cacheKey(_ taskID: String, record: DeviceRecord, instanceID: String? = nil) -> String { "\(record.id.uuidString):\(instanceID ?? record.instanceID ?? "unknown"): \(taskID)" }
    private func isCurrent(_ record: DeviceRecord, _ value: Int) -> Bool { foreground && generation == value && selectedDeviceID == record.id && selectedProfile?.instanceID == record.instanceID }
    private func updateProfile(_ id: UUID, _ body: (inout DeviceRecord) -> Void) { guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }; body(&profiles[index]); persistProfiles() }
    private func publish(_ key: String) { if let reducer = reducers[key] { logStates[key] = reducer.state } }
    private func logStates(for key: String) -> EventLogState? { logStates[key] }
    private func stopPolling(_ key: String) { pollingTasks[key]?.cancel(); pollingTasks[key] = nil; pollingIDs[key] = nil }
    private func invalidateOperations() { refreshOperationID = nil; submissionOperationID = nil; isRefreshing = false; isSubmitting = false }
    private func clearDeviceData() { tasks = []; projects = []; agents = []; snapshots = [:]; reducers = [:]; provisional = []; fallbackKeys = []; logStates = [:]; attempts = [:]; pollingTasks.values.forEach { $0.cancel() }; pollingTasks = [:]; pollingIDs = [:] }
    private func invalidateConnections() { sockets.values.forEach { $0.task.cancel(with: .goingAway, reason: nil) }; sockets = [:]; reconnectTasks.values.forEach { $0.cancel() }; reconnectTasks = [:]; pollingTasks.values.forEach { $0.cancel() }; pollingTasks = [:]; pollingIDs = [:] }
    private func stopStreaming(for taskID: String) { sockets[taskID]?.task.cancel(with: .normalClosure, reason: nil); sockets[taskID] = nil; reconnectTasks[taskID]?.cancel(); reconnectTasks[taskID] = nil }
    func stopStreaming(for deviceID: UUID) { guard selectedDeviceID == deviceID else { return }; invalidateConnections() }
    func appDidEnterBackground() { foreground = false; generation += 1; invalidateConnections(); invalidateOperations() }
    func appWillEnterForeground() { foreground = true; generation += 1; Task { await refreshSelectedDevice(); guard let record = selectedProfile else { return }; if pendingReviewDeviceIDs.contains(record.id) { banner = "提交结果未知，请核对任务列表后确认" }; let value = generation; let running = tasks.filter { !$0.status.isTerminal }; running.forEach { startStreaming($0.taskID, record: record) }; for task in tasks { let key = cacheKey(task.taskID, record: record); if fallbackKeys.contains(key) { beginPolling(task.taskID, record: record, instanceID: record.instanceID ?? "", generation: value, after: 0) } } } }
    private func isTransport(_ error: Error) -> Bool { if let value = error as? DotsCoreError, case .httpStatus(let code, _) = value { return (500...599).contains(code) }; return true }
    private func friendly(_ error: Error) -> String { if let value = error as? DotsCoreError { if case .httpStatus(let code, _) = value { return [401: "Token 无效，请检查设备 Token", 404: "项目或任务不存在", 409: "会话仍在执行，暂时不能继续", 422: "请求格式不正确", 503: "设备当前不可用或容量已满"][code] ?? (value.errorDescription ?? "设备请求失败") }; return value.errorDescription ?? "设备请求失败" }; return error.localizedDescription }
}
