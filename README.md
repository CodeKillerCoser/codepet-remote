# CodePet Remote

CodePet Remote 是面向 CodePet Host 的独立 Remote Client。客户端只通过可替换 channel 连接 Gateway，不连接 Codex App Server、Codex Desktop IPC，也不认识任何 Provider 原生 DTO。

## 当前范围

- 设备与 Gateway 连接入口
- LAN admission v1 QR pairing with leaf-certificate SHA-256 pinning
- Android Keystore-backed opaque credentials and persisted device metadata
- 双向 `DeviceDescriptor` pairing/handshake，随后建立一次 `event.subscribe`
- `conversation.list` 的 Host 逻辑项目投影
- `conversation.get` 的有序 committed history
- Gateway v2 JSON-RPC 2.0 typed client 与 opaque-cursor server event stream
- 会话列表与会话详情
- `turn.outputDelta` 增量消息投影及 snapshot content 去重
- 无 Host 时可使用本地演示数据检查完整 UI 链路

Gateway v2 的事实来源是 CodePet `protocol/gateway/v2` 与 `protocol/core/v1`；pairing DTO 来自 `protocol/channel/lan/v1`。`sdk/gateway` 和 `sdk/lan` 是 `cp-sdk-gen` 的签入输出，不手改。Remote 使用四段 `RoutedResourceId` 处理 wire 身份，再映射为 UI 所需的最小领域投影。

## 目录

```text
lib/
  app/                         应用生命周期与连接会话
  admission/                   pairing/credential 准入公开边界
  channel/                     discovery、TLS pin、WSS transport 公开边界
  features/connection/         设备连接入口
  features/conversations/      会话列表和详情
  gateway/                     Gateway 领域投影、生成 SDK adapter 与演示客户端
sdk/
  gateway/                     cp-sdk-gen --package gateway --role client 输出
  lan/                         cp-sdk-gen --package lan-channel --role models 输出
```

## 本地运行

环境基线：Flutter 3.47.2、Dart 3.13.2、JDK 17、Android API 36。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

Android SDK 首次使用需要由开发者本人阅读并接受 Google 许可证：

```sh
flutter doctor --android-licenses
```

## LAN transport 边界

正式 LAN channel 优先使用已保存的 preferred WSS endpoint；连接失败时，可从前台 `_codepet._tcp.local.` 发现中选择 `deviceId` 相同且版本范围包含 v2 的候选 host/port。mDNS 只提供 endpoint 候选，不更新 TLS pin、deviceId 或其他信任信息：

- 仅接受 `wss://` URI，不降级到明文 `ws://`
- 一个 WebSocket 承载标准 JSON-RPC 2.0 request、response 和 notification
- typed method wrapper、DTO 和 event decoder 全部来自生成的 Gateway SDK；channel 不维护 method string
- 从实际 peer leaf X509 DER 计算 SHA-256，并与 QR pin 常量时间比较
- 以 Android 安全存储中的 opaque credential 发送 Bearer authorization
- TLS channel 核对 identityFingerprint；Gateway handshake 只核对 Host deviceId，并在通过后刷新 Host descriptor
- `conversation.list` 和 `conversation.get` 使用 opaque `snapshotCursor` fence 安装订阅窗口；cursor 只比较相等性，不解析或持久化
- 同一 WebSocket 订阅内按 opaque `eventCursor` 去除 replay window 内的完全重复事件，去重缓存保持有界

普通存储只保存设备 descriptor、连接身份、endpoint、TLS 指纹、clientId 与 credential key reference；credential、会话、消息、Turn、live output 和 cursor 均不写入普通持久层。项目仅按 Host 投影的 `workspaceRoot` 分组，Remote 不读取 Git/worktree 元数据。详情先安装 `conversation.get.items` 的有序 committed snapshot，再应用 `snapshotCursor` 之后的 live output；已经由相同 `contentId` 提交的重放 delta 会被丢弃，terminal turn 则重新拉取 snapshot 并清理对应 live output。

## 分层约束

- discovery：只产生 endpoint candidate。
- channel：只传输 JSON-RPC object，并负责 TLS pin、Bearer 和连接生命周期。
- admission：通过 pinned HTTPS pairing 建立设备级 credential；成功后可访问 Host 的全部 Provider。
- gateway：只调用生成 `ProtocolClient`；所有 Provider 范围资源携带 `deviceId + providerPluginId + providerInstanceId`。

新增 localhost 或 WebRTC 接入时，只实现 channel contract；Gateway 业务调用继续复用 `sdk/gateway`。新增 admission 机制时也不得修改 Gateway method 或把证书/secret 写进 handshake。
