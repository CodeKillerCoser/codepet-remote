# WebRTC 通道开发状态

2026-09-09：已实现原生 RTC 通道，默认 LAN/WSS 保留；公网信令与 TURN 待后续交付。
文件挂载、上传下载和预览不在本轮范围。

## 使用

先按既有 LAN 流程配对，再以 `--dart-define=CODEPET_WEBRTC=true` 构建/启动 Remote。
组合入口选择 WebRtcGatewayTransport；GatewayClient、业务方法和界面不判断通道。
未设置此开关时继续原 LAN/WSS。旧设备记录、TLS pin、credential 不迁移。

此阶段仍需要 LAN HTTPS 信令可达，不能将 Wi-Fi 互通等同于公网完成。
信令接口独立为 RtcSignaling；当前 PinnedLanRtcSignaling POST 标准 SDP 至
`/remote/v1/webrtc/offer`，沿用证书 pin 和 bearer。没有 STUN/TURN 服务配置。

## 实现与边界

- `lib/gateway/webrtc/`：JSON-RPC 关联、CPG1 分片重组、发送队列、native peer 和信令。
- `lib/app/`、`lib/channel/`：仅负责通道选择和导出。
- `lib/security/pinned_tls.dart`：保留 HTTP status 给信令判断是否重试；
  401/403 与证书 pin 失败不可自动重试。
- 锁定 flutter_webrtc 1.6.2+hotfix.1；Host 使用 webrtc 0.14.0。
- 原生可靠、有序、negotiated ID 0，label=codepet.gateway.v1，
  protocol=codepet.gateway.cpg1。显式关闭 OfferToReceiveAudio/Video。
- 16 KiB 原生帧含 12 字节 CPG1 头；请求 256 KiB/响应 4 MiB；
  拼装期限 5 秒，native 高/低水位 64/16 KiB；64 个 pending 和 2 MiB 排队上限。
- 保留 outcomeUnknown，关闭/超时不自动重发业务写请求。
- 不新增音视频权限。完整帧契约以 Host
  `protocol/gateway/v1/webrtc-cpg1.md` 为准。

## 验证与签名

相关 Gateway、设备、发现、架构和 App 回归 180 项通过；
后续 RTC 与配对定向回归 14 项通过，最终 RTC 8 项通过。
Windows Host ↔ Android RMX3366 原生探针通过握手、大消息、心跳、事件和撤销。

`integration_test/rtc_gateway_test.dart` 配合 Host ignored 测试
`rtc_android_probe_host`，仅使用一次性配置。探针包名固定为
`com.codepet.remote.rtcprobe`，由 CODEPET_RTC_PROBE=true 选择，避免覆盖普通 App。
测试运行步骤与 Kotlin 跨盘缓存规避见 Host
`knowledge/40-runbooks/remote-webrtc-native-probe.md`。

按用户要求，Debug 和 CI Debug 固定使用已纳入仓库的
`android/keystore/codepet-debug.keystore`；Release 单独加载 CODEPET_RELEASE_*，缺少时失败。
启用 WebRTC 的普通 Debug APK 已构建成功，apksigner 证书指纹与仓库密钥一致，
包名为 com.codepet.remote。详情见 android-build.md；既有其他签名的覆盖安装未验证。

## 剩余交付

公网 rendezvous 与准入、TURN 凭据/部署、大陆移动网络、网络切换/重连及最终验收。
现有美国 VPS 尚未部署或修改。本轮没有把文件能力混入通道实现。
