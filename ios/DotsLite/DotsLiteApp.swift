import SwiftUI
import DotsCore

@main
struct DotsLiteApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .onChange(of: scenePhase) { phase in
                    if phase == .background { state.appDidEnterBackground() }
                    if phase == .active { state.appWillEnterForeground() }
                }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingDevice = false

    var body: some View {
        TabView {
            NavigationStack { TaskListView() }
                .tabItem { Label("任务", systemImage: "checklist") }
            NavigationStack { DeviceListView() }
                .tabItem { Label("设备", systemImage: "desktopcomputer") }
        }
        .tint(.indigo)
        .overlay(alignment: .top) {
            if let banner = state.banner {
                HStack(spacing: 10) { Text(banner).font(.footnote); if state.requiresSubmissionReview { Button("已核对任务列表") { state.acknowledgeSubmissionCheck() }.font(.caption).buttonStyle(.bordered) } }.foregroundColor(.white).padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.82), in: Capsule()).padding(.top, 8)
                    .onTapGesture { state.banner = nil }
            }
        }
        .task { if state.selectedProfile != nil { await state.refreshSelectedDevice() } }
    }
}

struct DeviceListView: View {
    @EnvironmentObject private var state: AppState
    @State private var draft = DeviceDraft()
    @State private var editing: DeviceRecord?
    @State private var showingEditor = false

    var body: some View {
        List {
            if state.profiles.isEmpty {
                EmptyStateView(title: "还没有设备", systemImage: "desktopcomputer", message: "添加一台 Windows Bridge 开始控制 Codex。")
            }
            ForEach(state.profiles) { profile in
                Button { state.selectDevice(profile.id); Task { await state.refreshSelectedDevice() } } label: {
                    HStack(spacing: 12) {
                        Circle().fill(profile.isOnline ? .green : .gray).frame(width: 11, height: 11)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name).font(.headline).foregroundColor(.primary)
                            Text(profile.baseURL).font(.caption).foregroundColor(.secondary)
                            if let error = profile.lastError, !profile.isOnline { Text(error).font(.caption2).foregroundColor(.orange).lineLimit(1) }
                        }
                        Spacer()
                        if state.selectedDeviceID == profile.id { Image(systemName: "checkmark.circle.fill").foregroundColor(.indigo) }
                    }.padding(.vertical, 5)
                }
                .swipeActions {
                    Button(role: .destructive) { state.deleteProfile(profile) } label: { Label("删除", systemImage: "trash") }
                    Button { editing = profile; draft = DeviceDraft(name: profile.name, baseURL: profile.baseURL, token: state.token(for: profile)); showingEditor = true } label: { Label("编辑", systemImage: "pencil") }.tint(.indigo)
                }
            }
        }
        .navigationTitle("设备")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { Button { Task { await state.refreshSelectedDevice() } } label: { Image(systemName: "arrow.clockwise") }.disabled(state.isRefreshing) }
            ToolbarItem(placement: .navigationBarTrailing) { Button { editing = nil; draft = DeviceDraft(); showingEditor = true } label: { Image(systemName: "plus") } }
        }
        .sheet(isPresented: $showingEditor) { DeviceEditor(profile: editing, draft: $draft) }
    }
}

struct DeviceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    let profile: DeviceRecord?
    @Binding var draft: DeviceDraft
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("设备") {
                    TextField("名称", text: $draft.name)
                    TextField("Bridge 地址", text: $draft.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Token（仅存入 Keychain）", text: $draft.token).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section { Text("Token 会使用 ThisDeviceOnly 保护。保存失败时不会保存设备配置。" ).font(.footnote).foregroundColor(.secondary) }
            }
            .navigationTitle(profile == nil ? "添加设备" : "编辑设备")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(saving || draft.name.isEmpty || draft.baseURL.isEmpty || draft.token.isEmpty) }
            }
        }
    }

    private func save() {
        saving = true
        let saved = DeviceRecord(id: profile?.id ?? UUID(), name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), baseURL: draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines), instanceID: profile?.instanceID)
        do { try state.saveProfile(saved, token: draft.token); dismiss(); Task { await state.refreshSelectedDevice() } }
        catch { state.banner = error.localizedDescription }
        saving = false
    }
}

struct TaskListView: View {
    @EnvironmentObject private var state: AppState
    @State private var showingComposer = false
    @State private var prompt = ""

    var body: some View {
        List {
            if state.selectedProfile == nil {
                EmptyStateView(title: "请先添加设备", systemImage: "desktopcomputer", message: "在设备页添加 Windows Bridge。")
            } else if state.tasks.isEmpty {
                EmptyStateView(title: "暂无任务", systemImage: "checklist", message: "创建一个任务开始工作。")
            } else {
                ForEach(groupedKeys, id: \.self) { key in
                    Section(conversationTitle(key)) {
                        ForEach(state.tasks.filter { $0.conversationID == key }) { task in
                            NavigationLink { TaskDetailView(taskID: task.taskID) } label: { TaskRow(task: task) }
                        }
                    }
                }
            }
        }
        .navigationTitle(state.selectedProfile?.name ?? "任务")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) { Button { Task { await state.refreshSelectedDevice() } } label: { Image(systemName: "arrow.clockwise") }.disabled(state.isRefreshing || state.selectedProfile == nil) }
            ToolbarItem(placement: .navigationBarTrailing) { Button { showingComposer = true } label: { Image(systemName: "plus") }.disabled(!canCreate) }
        }
        .sheet(isPresented: $showingComposer) { TaskComposer() }
        .refreshable { await state.refreshSelectedDevice() }
    }

    private var canCreate: Bool { state.selectedProfile?.isOnline == true && !state.projects.isEmpty && state.agents.contains(where: { $0.available }) }
    private var groupedKeys: [String] { Array(Set(state.tasks.map(\.conversationID))).sorted { firstDate($0) > firstDate($1) } }
    private func firstDate(_ key: String) -> Date { bridgeDate(state.tasks.first(where: { $0.conversationID == key })?.createdAt) ?? .distantPast }
    private func conversationTitle(_ key: String) -> String { "会话 · " + String(key.prefix(8)) }
}

struct TaskRow: View {
    let task: TaskSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("任务 " + task.taskID.prefix(8)).lineLimit(1); Spacer(); Text(task.status.title).font(.caption).foregroundColor(task.status == .failed ? .red : .secondary) }
            HStack { Text(task.agentID).font(.caption2).foregroundColor(.secondary); if let date = bridgeDate(task.createdAt) { Text(date, style: .relative).font(.caption2).foregroundColor(.secondary) } }
        }.padding(.vertical, 3)
    }
}

struct TaskComposer: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var state: AppState
    @State private var prompt = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    Picker("项目", selection: Binding(get: { state.selectedProjectID ?? "" }, set: { state.selectedProjectID = $0 })) { ForEach(state.projects) { Text($0.name).tag($0.id) } }
                    Picker("Agent", selection: $state.selectedAgentID) { ForEach(state.agents.filter(\.available)) { Text($0.id).tag($0.id) } }
                    TextEditor(text: $prompt).frame(minHeight: 160)
                }
            }
            .navigationTitle("新建任务")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("发送") { Task { if await state.createTask(prompt: prompt) { dismiss() } } }.disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.count > 32000 || state.isSubmitting || !canSubmit || state.requiresSubmissionReview) } }
        }
    }
    private var canSubmit: Bool { state.selectedProfile?.isOnline == true && state.selectedProjectID != nil && state.agents.contains(where: { $0.id == state.selectedAgentID && $0.available }) }
}

struct TaskDetailView: View {
    @EnvironmentObject private var state: AppState
    let taskID: String
    @State private var resumePrompt = ""
    @State private var showingResume = false

    var task: TaskSummary? { state.tasks.first(where: { $0.taskID == taskID }) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let task {
                    HStack { Label(task.status.title, systemImage: "circle.fill"); Spacer(); Text(task.agentID).font(.caption).foregroundColor(.secondary) }
                    Text(state.currentSnapshot(taskID)?.prompt ?? "加载任务…").font(.headline)
                    if let error = state.currentSnapshot(taskID)?.error { Text(error).foregroundColor(.red) }
                    if state.currentLogState(taskID)?.historyTruncated == true { Text("部分早期日志已截断").font(.caption).foregroundColor(.orange) }
                    else if state.currentSnapshot(taskID)?.outputTruncated == true { Text("设备只保留了输出尾部").font(.caption).foregroundColor(.orange) }
                    else if state.isLocallyTruncated(taskID) { Text("本机仅显示最近输出").font(.caption).foregroundColor(.orange) }
                    Text(state.output(taskID).isEmpty ? "等待输出…" : state.output(taskID)).font(.system(.body, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    HStack {
                        if !task.status.isTerminal { Button("取消", role: .destructive) { Task { await state.cancel(task) } }.buttonStyle(.bordered) }
                        if let current = state.currentSnapshot(taskID), state.canResume(current) { Button("继续会话") { showingResume = true }.buttonStyle(.borderedProminent) }
                    }
                } else { ProgressView() }
            }.padding()
        }
        .navigationTitle("任务详情")
        .task(id: "\(state.selectedDeviceID?.uuidString ?? "unknown"):\(state.selectedProfile?.instanceID ?? "unknown"):\(taskID)") { _ = await state.snapshot(taskID); guard !Task.isCancelled else { return }; if let task, !task.status.isTerminal { state.startStreaming(task.taskID) } }
        .sheet(isPresented: $showingResume) {
                    NavigationStack { Form { TextEditor(text: $resumePrompt).frame(minHeight: 150) }.navigationTitle("继续会话").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { showingResume = false } }; ToolbarItem(placement: .confirmationAction) { Button("发送") { if let current = state.currentSnapshot(taskID) { Task { if await state.resume(current, prompt: resumePrompt) { showingResume = false } } } }.disabled(resumePrompt.isEmpty || resumePrompt.count > 32000 || state.isSubmitting || state.requiresSubmissionReview) } } }
        }
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    var body: some View { VStack(spacing: 10) { Image(systemName: systemImage).font(.largeTitle).foregroundColor(.secondary); Text(title).font(.headline); Text(message).font(.footnote).foregroundColor(.secondary).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, minHeight: 180).padding() }
}
