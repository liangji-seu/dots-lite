# dots-lite

用 iPhone 调度个人电脑上的编程 Agent。Windows Bridge 支持 HTTP 下发任务、WebSocket 回放及实时输出、取消和继续会话。仓库包含原生 SwiftUI iPhone 客户端及可独立测试的 Swift 协议核心；真机验证进度见验收记录。客户端和服务端之间使用独立于厂商的协议；首个适配器是本机 Codex CLI。

## 架构

```text
iPhone / Mac 客户端（维护多台设备地址、各自 Token）
  ├─ HTTP + WebSocket → Windows Bridge → AgentAdapter → Codex CLI
  └─ HTTP + WebSocket → Mac Bridge（后续）→ AgentAdapter → 其他 Agent
```

每台设备独立认证、独立项目白名单、独立队列。没有中心服务器、跨设备任务迁移或公网 Relay。任务 ID 必须与 device.id 一起使用。详见 [架构决策](docs/ARCHITECTURE.md) 和 [Mac / iPhone 交接](docs/HANDOFF.md)。

## iPhone 客户端

[安装与真机验收步骤](ios/README.md)。本阶段聚焦 iPhone 通过 Tailscale 控制已有 Windows Bridge；Mac 作为开发机，不启动 Mac Bridge。

客户端支持本地管理设备、Keychain 保存 Token、白名单项目和 Agent 选择、会话任务列表、提交、输出、取消和续接。网络中断不会取消电脑任务；前台恢复会刷新状态并按事件序号回放，日志截断时明确提示并改用 REST 快照。提交结果不确定时需先核对任务列表，客户端不自动重发。

离线验证不会调用真实模型：

```sh
swift test --package-path ios/DotsCore
python scripts/smoke_iphone_client.py
```

第二条命令需要上面的 Python 3.11+ 开发环境和依赖，运行原生 URLSession 客户端连接临时 Bridge 测试执行器。它验证协议链路，不代表 iPhone 真机或 Windows 真实 Codex 任务已经验收。

## Windows 安装与启动

需要 Python 3.11+、已登录的 Codex CLI（本机验证版本 0.160.0）。

```powershell
git clone https://github.com/liangji-seu/dots-lite.git
cd dots-lite
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements-dev.txt
.\.venv\Scripts\python.exe scripts\configure.py
.\.venv\Scripts\python.exe run.py
```

配置脚本只在缺失时创建 `.env` 和 `config/projects.json`，生成随机 Token，默认仅允许本仓库作为项目。两个文件都不提交 Git。请在本机编辑白名单加入真实项目。配置改变后重启服务。

若安装时系统 Python 的 pip 初始化失败，可使用已有 uv：`uv pip install --python .venv\Scripts\python.exe -r requirements-dev.txt`。

默认监听 `0.0.0.0:8765`。Windows 用 `ipconfig` 查看正在联网的 IPv4，客户端使用 `http://<IPv4>:8765`，不能用 `0.0.0.0`。跨网络建议使用 Tailscale 设备地址；本项目不自动修改防火墙或路由。只向可信网络开放服务；HTTP 本身不加密，公网使用需要 TLS 与额外部署设计。

已经安装 Tailscale 时，在 Windows 执行 `tailscale ip -4`，将 `.env` 的 `CODEX_BRIDGE_HOST` 改为该 `100.x.x.x` 地址即可仅监听 Tailscale 网络。iPhone / Mac 加入同一 tailnet 后使用 `http://100.x.x.x:8765`，还需要输入 Bridge Token。设备在线不等于端口可达；若连接失败，应分别检查 Bridge 是否运行、Windows 防火墙以及 tailnet ACL。不要启用公网 Funnel 来替代私有网络配对。

## 配置

见 [.env.example](.env.example)。必须设置至少 24 字符的随机 `CODEX_BRIDGE_TOKEN`；环境变量优先于 `.env`。手机使用该设备的 Token，通过 `Authorization: Bearer <token>` 同时认证 HTTP 和 WebSocket。不要将 Token 放入 URL。

项目配置格式：

```json
[
  {"id":"my-project","name":"My Project","path":"C:\\Projects\\my-project"}
]
```

只能传 `project_id`，客户端不能传路径、命令行、模型或权限参数。默认 Codex 为 `read-only`；需要远程修改代码时由本机管理员把 `CODEX_SANDBOX` 改成 `workspace-write`，然后重启。项目白名单只控制启动目录，不是操作系统隔离边界；实际工具访问由 Codex 沙箱约束。不要把不可信仓库加入白名单。

## HTTP 快速测试

在 PowerShell 中设置 `$env:CODEX_BRIDGE_TOKEN` 为本机 `.env` 的值后：

```powershell
$headers = @{ Authorization = "Bearer $env:CODEX_BRIDGE_TOKEN" }
Invoke-RestMethod http://127.0.0.1:8765/api/device -Headers $headers
Invoke-RestMethod http://127.0.0.1:8765/api/projects -Headers $headers
$body = @{ project_id='dots-lite'; agent_id='codex'; prompt='Read README.md and describe this project briefly. Do not modify files.' } | ConvertTo-Json
$task = Invoke-RestMethod http://127.0.0.1:8765/api/tasks -Method Post -Headers $headers -ContentType application/json -Body $body
Invoke-RestMethod "http://127.0.0.1:8765/api/tasks/$($task.task_id)" -Headers $headers
```

curl 示例（Windows 请用 `curl.exe`）：

```sh
curl -H "Authorization: Bearer $CODEX_BRIDGE_TOKEN" http://127.0.0.1:8765/api/device
curl -H "Authorization: Bearer $CODEX_BRIDGE_TOKEN" -H "Content-Type: application/json" \
  -d '{"project_id":"dots-lite","prompt":"Summarize README.md without changing files."}' \
  http://127.0.0.1:8765/api/tasks
```

WebSocket 测试工具自动读取 `.env`，不打印 Token：

```powershell
.\.venv\Scripts\python.exe scripts\watch.py <task_id>
```

## Codex 调用

适配器使用 `codex exec --json`，prompt 经 stdin 传入，真实工作目录由服务端白名单决定。续接用明确的 `session_id` 调用 `exec resume`，不使用 `--last`。明确设置沙箱与非交互审批策略，跳过用户全局配置和额外执行规则，保留本机 Codex 登录。命令细节封装在 `bridge/adapters/codex.py`。

此设计依据本机 CLI 帮助和 [OpenAI 官方非交互文档](https://learn.chatgpt.com/docs/non-interactive-mode)。客户端收到通用状态／输出事件，厂商原始事件是可选扩展。

## 测试与限制

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

[验收记录](docs/VALIDATION.md) 区分自动化测试与真实 Codex 调用。CI 配置覆盖 Windows / macOS / Linux，CI 不调用付费模型。

- 单进程、单 worker，不要使用 uvicorn 多 worker 或开发热重载处理真实任务。
- 内存任务在服务重启后丢失；输出与事件有界，过旧输出会截断，客户端必须处理 gap。
- 默认最多保留 100 个任务，满后返回 503；可本机调整容量，或在保存需要的结果后重启清空。
- 本版无设备自动发现、推送通知、附件上传、交互审批 UI、自动开机服务；手机 App 的安装签名和真机验证仍需完整 Xcode。
- Codex 不保证逐 token 输出；Bridge 在 CLI 提供数据时立即转发。
- 续接仅针对本 Bridge 创建且仍保留的任务，不读取或控制桌面 App 中任意既有聊天。
- 只实现 Codex 适配器；Claude Code / DeepSeek 为扩展边界，未宣称已支持。

API 与客户端规则以 [API.md](docs/API.md) 及 [OpenAPI](docs/openapi.json) 为准。
