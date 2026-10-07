# 架构决策

## 1. 客户端协议不依赖 Agent 厂商

依赖方向为 API → TaskManager → AgentAdapter；Codex 命令行、JSONL 格式和进程控制只在适配器内出现。新 Agent 需要实现 `available`、`supports_resume`、`run(RunRequest, emit, cancel)`，注册后通过 `/api/agents` 宣告能力。请求只允许选择已注册的 `agent_id`，不能提交任意可执行文件。

现阶段不提供动态 Python 插件加载、通用 shell 端点或远程设置权限接口。这样可以保留扩展能力而不引入任意代码执行配置面。

## 2. 设备、项目、会话、任务各自有身份

- device：持久配置的逻辑设备 ID；instance_id 是本次服务启动标识。
- project：本机管理员定义的白名单别名；客户端不接触文件路径。
- conversation：多个任务的逻辑会话，固定设备、项目和适配器。
- task：一次 prompt 执行，具有独立状态和事件序列。继续消息创建新的 task，保留 parent_task_id 与 conversation_id。
- session_id：适配器使用的厂商会话标识。客户端不能任意注入它，也不应把它当跨厂商主键。

一台 Bridge 只有一个串行执行 worker。对于个人工具，这是避免代码并发修改的明确取舍。之后可以按项目加锁与隔离 worktree 扩展并发，而不更改 API 身份模型。同一 conversation 有未完成任务时，续接返回冲突。

## 3. 网络连接不拥有执行生命周期

TaskManager 拥有任务及子进程，WebSocket 仅订阅事件。断线不会取消任务。事件 seq 在每个 task 内递增，客户端保存游标并重放；截断明确报告 gap。客户端用终态判断结束，不能以网络关闭判断成功。

任务列表和日志均设置容量上限，避免长时间运行积累无限内存。第一版不承担永久审计存储；后续可把内存存储替换为 SQLite，将相同任务／事件契约落盘。使用 instance_id 让客户端识别重启并停止使用旧缓存。

## 4. 能力安全边界

Token 是整台 Bridge 的权限凭据，不是多用户权限系统。所有 API 和 WebSocket 都认证，Token 不进 URL、不写访问日志。拒绝浏览器 Origin；原生 iOS URLSession 可发送 Authorization 头，无需不安全的 query token 兼容。

自然语言 prompt 仍可以指示 Agent 执行工具，不能视为无害输入。白名单仅控制 cwd，Codex 沙箱控制其工具权限。默认只读，本机管理员可选择 workspace-write，服务端不支持 danger-full-access。非交互运行遇到需额外授权的操作会失败，不能由客户端跳过审批。

关闭服务、超时或取消会触发进程终止；Windows 使用进程树终止，其他平台使用进程组。已经发生的文件修改和外部操作不会因取消而回滚。

## 5. 后续演进顺序

1. SwiftUI iPhone 客户端，Keychain 保存设备 Token，URLSession 执行 HTTP / WebSocket；先验证 iPhone 控制已有 Windows Bridge。
2. Mac 复用 Python Bridge，验证平台进程生命周期和本机 CLI（本阶段暂不实现）。
3. SQLite 持久化、任务提交幂等键、模型预算、按项目并发与审批。
4. 添加 Claude Code / DeepSeek 适配器，通过相同契约测试。
5. 只有确实需要公网接入时才引入设备出站连接 Relay、设备配对和端到端认证。

不在本阶段范围：Mac 执行端、远程桌面、屏幕共享、自动同步 Git 工作区。
