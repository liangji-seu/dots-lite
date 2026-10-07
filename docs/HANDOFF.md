# Mac / iPhone 开发交接

## 目标与已有成果

仓库：`https://github.com/liangji-seu/dots-lite`，主分支 `main`。Windows 阶段实现通用任务 Bridge 和 Codex 适配器；并未创建 Xcode 工程。先阅读 README、ARCHITECTURE、API 与 VALIDATION，再开发客户端。`docs/openapi.json` 是 REST 契约，WebSocket 契约在 API.md 中单独定义。

Windows 本地 checkout 位于 `C:\Users\liangji\Documents\Codex\2026-10-07\wo\outputs\dots-lite`。私有 `.env` 与 `config/projects.json` 不在 Git；切换 Mac 后必须在 Mac 本地单独配置，不能复用 Windows 路径。设备 Token 由用户在 Windows 本地读取，再安全录入手机；不要提交源码或日志。

Windows 已安装并登录 Tailscale。当前本机服务配置为仅监听 Tailscale IPv4，真实地址由用户从 Windows `tailscale ip -4` 或本次交付的本地连接说明获取。Mac / iPhone 需加入同一 tailnet；不需要公网 Relay 或端口转发。本机可达检查不能代替跨设备联调。

## iPhone 第一版范围

建议 SwiftUI + URLSession。先实现手动添加设备（名称、baseURL、Token）、在线探测、项目选择、Agent 选择、任务列表、创建任务、输出视图、取消、继续会话。不需要服务端 Relay、自动发现或云账号。

- 设备列表保存在手机本地，Token 放 Keychain。每台设备各自认证。
- 用 `/api/device` 判断当前在线状态；连接失败不应删除设备或本地任务。
- 缓存标识使用 `(device.id, instance_id, task_id)`；instance_id 改变表示服务重启，重新拉取列表。
- HTTP 与 WebSocket 均发送 Authorization Bearer 请求头。原生 URLSessionWebSocketTask 使用 URLRequest 设置头；不能把 Token 拼入 URL。不要设置浏览器 Origin。
- HTTP baseURL 切换成对应的 ws / wss scheme，保留 host / port / path。
- 展示通用 `output.text` 与任务状态。Codex stdout 本身是 JSONL；首版可作为日志原样显示，丰富界面可读取 provider_event，但业务状态不能依赖某厂商 JSON 格式。
- 保存每个任务的 seq，断线后 `?after=<last_seq>`，按 seq 去重。处理 gap 提示历史输出截断，用 REST 重新获取当前快照。
- App 进入后台时不假设 WebSocket 持续运行；回到前台刷新状态并回放。后台推送不在此版。
- 继续对话会返回新 task_id；保留会话分组，不覆盖老任务。409 表示该会话仍忙。
- POST 提交没有幂等键；请求超时后先刷新任务列表并让用户确认，不能自动无限重发。
- 401 提示检查设备 Token；404 提示任务／项目不存在；422 显示请求校验错误；503 表示容量或执行器不可用。

局域网访问需在真实 iPhone 上验证系统本地网络授权与 ATS 配置。只为所需的本地网络开发配置例外，正式远程连接优先采用可信 TLS／Tailscale 部署。根据当前 Apple 官方文档确认具体配置，不能把模拟器成功当作真机成功。

## Mac Bridge

Python 代码已有 POSIX 进程组处理，仍需在 Mac 实机验证。使用独立虚拟环境安装依赖，`python scripts/configure.py` 后调整 device ID、项目白名单与 Codex 可执行路径，先运行离线测试，再明确执行 `python scripts/smoke_live.py`（会消耗模型用量）。不要改变现有 API 路径或状态含义来适应 Swift 模型。

建议先从 iPhone 连接 Windows，完成端到端，再配置 Mac 作为第二台设备。服务默认不是开机常驻；Mac launchd 与 Windows 自动启动可以另做阶段。

## 验收标准

1. 真机添加 Windows 和 Mac 两台设备，准确显示在线／离线。
2. 只能选择返回的白名单项目与已注册 Agent。
3. 创建任务后，在任务结束前可收到输出，最终 REST 与 WebSocket 状态一致。
4. 断网／后台再回来可恢复输出，无重复、无静默丢失；gap 可见。
5. 错误 Token 拒绝 HTTP 与 WebSocket，Token 不出现在日志或 URL。
6. 排队和执行中的任务均可取消；重复取消有可解释结果。
7. 完成任务可继续，产生新的 task_id 并保持同一 conversation。
8. 设备重启后的 instance_id 变化被正确处理，不把旧缓存当作当前记录。
9. 客户端协议不写死 codex；新增 Agent 由 `/api/agents` 驱动。

## 可直接交给 Mac Codex 的提示词

> 请接手 https://github.com/liangji-seu/dots-lite 的 main。先阅读 README.md、docs/ARCHITECTURE.md、docs/API.md、docs/HANDOFF.md、docs/VALIDATION.md 和 docs/openapi.json。Windows Bridge 已完成首版，本阶段负责 SwiftUI iPhone 客户端，并在 Mac 验证同一 Python Bridge。遵守现有 AgentAdapter 分层和统一协议，不把客户端绑定 Codex。实现手动管理多设备、Keychain Token、项目／Agent 列表、任务提交、实时输出、断线 seq 回放与 gap、取消和续接。先用 Windows 设备完成真机联调，再把 Mac 加为第二台设备。凭据和机器路径不入 Git。REST 已有 OpenAPI，WebSocket 依 API.md。检查 VALIDATION 中未验证项并诚实记录；不要把模拟测试当成真实设备通过。完成后提交代码、实测证据和剩余问题。用户希望节约强模型用量，边界清晰的执行工作使用 gpt-5.6-luna，最多两个执行子智能体，不递归委派。
