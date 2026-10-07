# dots-lite API v1

Base URL：`http://<device-host>:8765`。所有 `/api/*` 路由必须带 `Authorization: Bearer <token>`，包括 WebSocket 握手。原生客户端不发送 Origin。公开健康探测 `/healthz` 不包含项目或输出。时间为 UTC ISO 8601 字符串。

设备返回 `api_version: 1` 与每次启动变化的 `instance_id`。没有中央设备列表接口；手机自行维护已配对设备 URL 并逐台查询。

## REST

| 方法 | 路径 | 含义 |
| --- | --- | --- |
| GET | `/api/device` | 本机身份、平台与能力 |
| GET | `/api/projects` | `[{id,name}]`，不公开绝对路径 |
| GET | `/api/agents` | `[{id,available,supports_resume}]` |
| POST | `/api/tasks` | 创建任务，201 |
| GET | `/api/tasks?offset=0&limit=50` | `{items,offset,limit,total}`，不含完整输出 |
| GET | `/api/tasks/{task_id}` | 任务快照与保留的输出 |
| POST | `/api/tasks/{task_id}/cancel` | 请求取消，返回当前快照 |
| POST | `/api/tasks/{task_id}/messages` | 继续会话，创建新任务，201 |

创建请求：

```json
{"project_id":"dots-lite","agent_id":"codex","prompt":"检查 README，不修改文件。"}
```

`agent_id` 缺省为 `codex`。`prompt` 1–32000 字符。额外字段拒绝（422）；不得传 cwd、shell、session_id、模型或权限选项。

续接请求：

```json
{"prompt":"继续解释架构。"}
```

续接要求父任务终态、适配器支持 resume 且已有厂商 session_id；同一会话已有 queued/running 任务时返回 409。返回新的 task_id；conversation_id 保持，parent_task_id 指向所请求的父任务。厂商会话会追加历史，调用旧父任务并不表示分支或回滚历史。

任务快照字段：

```json
{
  "task_id":"uuid", "project_id":"dots-lite", "agent_id":"codex",
  "prompt":"检查 README，不修改文件。", "status":"queued",
  "created_at":"2026-10-07T13:00:00Z", "started_at":null, "finished_at":null,
  "exit_code":null, "output":"", "error":null, "output_truncated":false,
  "session_id":null, "parent_task_id":null, "conversation_id":"uuid"
}
```

状态转换：`queued → running → completed | failed | cancelled`；排队时也可以直接 cancelled。超时是 failed，error 描述原因。取消运行中的任务是异步请求，返回值可能仍为 running；继续订阅／查询直到终态。重复取消终态任务不重跑。退出码 0 且无适配器错误才是 completed。

任务列表按创建顺序从旧到新分页。默认最多保留 100 个任务，容量满后新提交返回 503；本版不自动删除历史，重启或在本机提高 CODEX_MAX_TASKS 后可继续。重启会清空历史并取消活跃任务。

错误返回通常是 `{"detail":"..."}`；422 detail 是框架校验错误数组。401 认证失败；403 Origin 不允许；404 项目／任务不存在；409 会话冲突或无法续接；413 请求体过大；422 请求格式不正确；503 执行器不可用或容量已满。

## WebSocket

`ws://<device-host>:8765/api/tasks/{task_id}/stream?after=0`

用 Authorization 请求头认证，不支持 query token。握手前拒绝通常表现为 HTTP 403；已接受连接后的非法游标以 1008 关闭。正常发送完终态以 1000 关闭。

持久于当前进程内存的事件携带 `seq`（每任务从 1 开始单调递增）、`task_id`、`timestamp`。客户端按 seq 去重，重连请求严格大于 after 的事件：

```json
{"type":"status","task_id":"uuid","seq":1,"timestamp":"...","status":"queued"}
{"type":"output","task_id":"uuid","seq":3,"timestamp":"...","stream":"stdout","text":"..."}
{"type":"session","task_id":"uuid","seq":4,"timestamp":"...","session_id":"provider-session"}
{"type":"status","task_id":"uuid","seq":9,"timestamp":"...","status":"completed","exit_code":0,"error":null}
```

`output` 是原始 UTF-8 流片段，不保证一段等于一行；Codex stdout 的内容是 JSONL。不要按 output 次数推断 token 数或任务进度。`provider_event` 是可选厂商事件，基础客户端可以忽略。

游标落后于已保留日志时，先发无 seq 的控制消息，再发当前仍保留的事件：

```json
{"type":"gap","task_id":"uuid","timestamp":"...","after":10,"oldest":40}
```

显示“部分早期日志已截断”；获取 REST 快照中 output 尾部。gap 与 heartbeat 均不推进游标。心跳 `{"type":"heartbeat","task_id":"uuid","timestamp":"..."}` 用于空闲连接保活。

事件日志默认同时受 2048 条与 512 KiB 序列化大小限制。单个过大事件用有 seq 的 `{"type":"truncated","original_type":"provider_event","original_bytes":1234567,...}` 替代；应显示截断提示并推进游标。stdout/stderr 正常分块转发，REST 输出尾部另受 262144 字符限制。

REST output 是 stdout/stderr 按接收顺序拼接的有界尾部，output_truncated 明示截断。REST 快照不是事件游标快照：不要把它与已展示的流直接拼接，重连应使用 seq。已完成任务以 after=最后 seq 重连时，应立即正常关闭。

## 稳定性与重启

队列、任务记录与事件保存在内存，重启不恢复，instance_id 会改变。API v1 无提交幂等键，POST 超时后不能盲目重试；先刷新列表判断是否已创建。WebSocket 网络断开不改变任务状态。慢客户端可能遇到 gap，而不会阻塞 Agent 任务执行。

客户端应忽略未知可选字段和未知事件类型，以兼容未来扩展；对未知任务状态显示原值并刷新，不假定成功。REST OpenAPI 见 [openapi.json](openapi.json)。
