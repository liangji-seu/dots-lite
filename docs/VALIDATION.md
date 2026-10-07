# Windows 验收记录

日期：2026-10-07（Asia/Shanghai）。本机 Windows，Python 3.14.6，Codex CLI 0.160.0，使用已登录 ChatGPT 账户。

## 自动化测试

完整回归 `python -m pytest -q`：**13 passed**，约 21.8 秒；随后补充超时和关闭生命周期用例，`tests/test_manager.py` 的 **4 项全部通过**（其中 2 项为新增）。合计 **15 个通过的用例**。覆盖真实测试子进程的取消、stdout/stderr 与 session 捕获、turn.failed、HTTP/WS 鉴权、Origin 拒绝、项目和参数注入拒绝、断线不取消任务、终态／超前游标、续接身份和冲突、队列取消、关闭与超时、事件回放／字节上限、OpenAPI 响应类型和 Bearer 定义。

有一条依赖库 Starlette 关于未来 TestClient HTTP 后端的弃用提示，不影响本次通过。由于 Codex 执行环境限制创建 Windows 子进程，测试在经授权的本机执行环境运行；没有把受限环境挂起当作测试通过。

## 真实模型与网络链路

通过 `scripts/smoke_live.py` 启动临时 loopback HTTP 服务，使用真实 HTTP 与 WebSocket 客户端、真实 Codex 可执行程序；不是 FakeAdapter。本机配置选择 `gpt-5.6-luna`、high、read-only。

| 项目 | 结果 |
| --- | --- |
| GET /api/device | 200 |
| GET /api/projects | 200 |
| 无 Token / 错 Token | 均 401 |
| 非法 project_id | 404 |
| 注入 cwd 字段 | 422 |
| 读取项目 README 的真实任务 | completed，exit_code=0 |
| 任务完成前接收到输出 | 通过，首个片段约 0.47 秒 |
| 首任务流事件 | 50 条；总耗时约 137.13 秒 |
| 首任务断线重连回放 | seq 严格匹配预期，通过 |
| 继续同一 Codex 会话 | completed，exit_code=0，session_id 相同 |
| 续接回复内容 | 包含 DOTS_RESUME_OK |
| 续接流事件与回放 | 36 条，回放通过；总耗时约 118.27 秒 |

首任务 ID：`d6130643-c6c0-4302-9035-6408aba7c792`。
续接任务 ID：`ead8b01c-a96c-4a73-a464-345afc07c435`。
Codex session ID：`01a11691-00fb-7942-8cd7-5b80c5402cc0`。

这些 Bridge 任务位于临时测试服务的内存中，服务已停止，不能在重新启动的服务中查询。无 Token 的本地结果文件保存在 `.local/live-validation.json`（不提交）；服务器日志也仅留本地。

模型网络曾发生多次 request timed out，Codex 自动重试后完成。延迟不是稳定性能指标，也不代表生产 SLA。没有更改本机代理或网络设置。

## 验证边界

- Windows 真机：HTTP、WebSocket、真实 Codex 初始执行和续接已通过。
- Windows 取消：自动化测试使用真实测试子进程，避免浪费模型用量。
- 尚未使用真实 iPhone / Mac 连接；局域网隔离、防火墙、iOS 网络权限仍需下一阶段验证。
- macOS / Linux CI 已配置，不能在尚未查看 CI 结果时宣称通过。
- 不测试远程写文件，因为当前本机默认 read-only；切换 workspace-write 后需单独验收。
- 最终版本已在 Windows 后台启动，仅绑定本机 Tailscale IPv4，并通过该地址完成带 Token 的 GET /api/device（200）。未安装为 Windows 服务、未修改防火墙；重启电脑后需重新启动 Bridge。
