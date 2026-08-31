# CodePet Remote

CodePet Remote 是面向 CodePet Host 的独立 Remote Client。v1 以 Android 为首要平台，只通过安全的局域网 Gateway 连接电脑端；客户端不连接 Codex App Server、Codex Desktop IPC，也不认识 Codex 原生 DTO。

## 当前范围

- 设备与 Gateway 连接入口
- Gateway v1 QR pairing with leaf-certificate SHA-256 pinning
- Android Keystore-backed opaque credentials and persisted device metadata
- `protocol.handshake` followed by one `event.subscribe`
- `conversation.list`
- `conversation.get`
- Gateway v1 opaque-cursor server event stream
- 会话列表与会话详情
- `turn.outputDelta` 增量消息投影
- 无 Host 时可使用本地演示数据检查完整 UI 链路

Gateway v1 的事实来源是 CodePet `protocol/gateway/v1` 与 `protocol/core/v1`。Remote 使用四段 `RoutedResourceId` 处理 wire 身份，再映射为 UI 所需的最小领域投影，不复制 Codex Provider 的原生 DTO。

## 目录

```text
lib/
  app/                         应用生命周期与连接会话
  features/connection/         设备连接入口
  features/conversations/      会话列表和详情
  gateway/                     DTO、协议客户端、transport 与演示客户端
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

正式 LAN transport 使用 Host pairing response 返回的固定 WSS URL：

- 仅接受 `wss://` URI，不降级到明文 `ws://`
- 一个 WebSocket 同时承载 JSON request、response 和 server event frame
- 请求/响应/event envelope 与 Gateway v0 生成契约一致
- 从实际 peer leaf X509 DER 计算 SHA-256，并与 QR pin 常量时间比较
- 以 Android 安全存储中的 opaque credential 发送 Bearer authorization
- handshake 再次核对 Host deviceId 与 identityFingerprint

普通存储只保存设备身份、endpoint、TLS 指纹、clientId 与 credential key reference；credential、会话、消息、Turn、live output 和 cursor 均不写入普通持久层。

`conversation.get` 在当前 Gateway v1 Host 中只返回会话元数据与 snapshotCursor，不包含历史消息正文。详情页会明确展示这一限制。
