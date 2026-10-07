# Dots Lite iPhone 客户端

SwiftUI iOS 16+ 客户端用于控制 Tailscale 网络中的 Windows Bridge。客户端只连接 `/api` 契约，不读取 Codex 凭据，也不会把 Token 放入 URL 或日志。

## 运行

仓库已提交可直接打开的 `DotsLite.xcodeproj`，用 Xcode 打开后等待本地 Swift Package `DotsCore` 解析即可。`project.yml` 和 `generate_project.sh` 仅作为可选的 XcodeGen 来源，不是运行前置依赖。项目没有写死签名 Team；个人免费签名可在 Xcode 的 Signing & Capabilities 中选择个人 Team，Bundle Identifier 为 `com.liangji.dotslite`（若账号冲突可改成自己的唯一后缀）。

首次打开时进入“设备”，添加 Windows Bridge。地址输入框会以 `http://100.x.x.x:8765` 作为提示，名称和地址都可编辑；Token 必须手工输入，保存到 ThisDeviceOnly Keychain。手机和 Windows 必须加入同一 Tailscale 网络，首次访问需允许系统本地网络权限。

任务页会读取 Bridge 返回的项目和 Agent 白名单，支持分页加载全部任务、按 conversation 分组、创建、取消和继续会话。输出通过 WebSocket 实时接收，按每个设备、实例和任务保存 seq；断线会限次退避重连，gap 会提示并用 REST 快照刷新。进入后台会关闭连接，回到前台会刷新设备状态和任务。POST 超时或传输失败会提示提交结果未知并刷新列表，不自动重发。

## 构建与验收

已用 Xcode 的 iOS Simulator SDK 完成无签名构建：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project DotsLite.xcodeproj -scheme DotsLite \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath ../.local/DerivedData CODE_SIGNING_ALLOWED=NO build
```

这只证明模拟器 SDK 构建通过，尚未证明真机联网或签名通过。个人免费签名与真机验收还需在 Xcode 中选择 Team，验证本地网络授权、错误 Token、断网恢复、后台恢复、任务取消和继续会话。

如当前环境没有 Xcode，可用 Swift 6.1.2 的命令行前端做语法检查：

```sh
find DotsLite -name '*.swift' -print0 | xargs -0 -n1 swiftc -frontend -parse
```

该检查不等于 Xcode 编译。Windows Bridge 的真实联调证据见仓库 `docs/VALIDATION.md`。
