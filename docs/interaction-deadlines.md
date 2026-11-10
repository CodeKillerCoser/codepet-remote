# 接管响应的等待期限

2026-11-10 调整：LAN 和 RTC 共用 `lib/gateway/request_deadline.dart`。普通请求保留 30 秒；
`conversation.acquireInteraction` 与 `conversation.resume` 为 75 秒，覆盖新版 Host 的 45 秒
acquire、合并 resume 后续 10 秒历史及网络余量。修改需与桌面 Host 一并构建部署。

收到成功响应之前不得假设已接管。真正超时仍返回 `outcomeUnknown`，不因单次超时断开通道；
已有请求 ID 隔离与迟到响应丢弃继续有效。Ready 状态、历史内容和事件不能代替接管确认。

RTC 回归在 `test/gateway/webrtc_transport_test.dart`：31 秒响应可接收，普通请求仍 30 秒失败，
76 秒无响应时报告结果未知，之后通道仍可用。四组传输、Gateway 和会话页面测试共 151 项通过。

Android API 36 原生网络栈验收使用 `integration_test/interaction_deadline_test.dart`。在临时目录用
`openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost` 生成仅供测试的证书与私钥；
将 PEM 文件分别 base64 编码后写入 JSON 键 `TEST_TLS_CERT_B64`、`TEST_TLS_KEY_B64`，运行：

```sh
flutter test integration_test/interaction_deadline_test.dart -d emulator-5554 --dart-define-from-file=/tmp/codepet-control-diagnostic/defines.json
```

测试在模拟器内启动隔离 TLS/WebSocket 服务，31 秒后回复一次 acquire/resume；不访问用户 Host
或真实会话。该测试已通过；它验证延迟回包处理，不证明用户那一次现场 timeout 的唯一原因。
现场还需对照桌面 `interaction.rpc.started/completed` 和手机 RPC 日志，区分 Host 超时与传输超时。
