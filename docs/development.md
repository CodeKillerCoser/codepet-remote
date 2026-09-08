# 开发指南

[文档导航](README.md) · [项目首页](../README.md)

## 本地运行

环境基线：Flutter 3.47.2、Dart 3.13.2、JDK 17、Android API 36。

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

CI 会在 `main` push 和 Pull Request 上执行 analyze、全量测试和 Android
debug 构建。

## 目录

```text
lib/
  app/                         Composition Root 与 Flutter 应用生命周期
  core/domain/                 稳定领域模型、资源身份与状态转换
  application/ports/           Gateway、设备仓储、身份与配对端口
  application/sessions/        Host 运行时、重连与列表投影
  application/conversations/   搜索/详情用例控制器
  application/pairing/         配对用例编排
  admission/                   pairing/credential 准入公开边界
  channel/                     discovery、TLS pin、WSS transport 公开边界
  features/connection/         设备连接入口
  features/conversations/      会话列表和详情
  gateway/                     Gateway 领域投影、生成 SDK adapter 与演示客户端
sdk/
  gateway/                     cp-sdk-gen --package gateway --role client 输出
  lan/                         cp-sdk-gen --package lan-channel --role models 输出
```

## 协议与生成 SDK

Gateway v1 的事实来源是 CodePet 的 `protocol/gateway/v1` 与 `protocol/core/v1`；配对 DTO 来自 `protocol/channel/lan/v1`。`sdk/gateway` 和 `sdk/lan` 是 `cp-sdk-gen` 的签入输出，不手工修改。Remote 使用四段 `RoutedResourceId` 处理 wire 身份，再映射为 UI 所需的最小领域投影。

## 本地演示

项目包含 `DemoGatewayClient`，开发和 UI 测试可通过 `CodePetRemoteApp(includeDemoDevices: true)` 注入演示设备。默认入口不启用演示；演示回复不代表真实 AI 执行结果。

## 分层约束

- core/domain：不依赖 Flutter、I/O、生成 SDK 或外层代码。
- application：只依赖 core 和 application 自己定义的 ports；控制器为纯 Dart。
- features：只调用 application 用例/控制器和领域投影，不直接访问 Gateway、TLS、存储或生成 DTO。
- app：唯一的 composition root，负责选择并注入基础设施实现。
- discovery：只产生 endpoint candidate。
- channel：只传输 JSON-RPC object，并负责 TLS pin、Bearer 和连接生命周期。
- admission：通过 pinned HTTPS pairing 建立设备级 credential；成功后可访问 Host 的全部 Provider。
- gateway：只调用生成 `ProtocolClient`；所有 Provider 范围资源携带 `deviceId + providerPluginId + providerInstanceId`。

新增 localhost 或 WebRTC 接入时，只实现 channel contract；Gateway 业务调用继续复用 `sdk/gateway`。新增 admission 机制时也不得修改 Gateway method 或把证书/secret 写进 handshake。

完整设计见[架构文档](architecture.md)。
