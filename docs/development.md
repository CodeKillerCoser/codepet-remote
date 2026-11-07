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

### Quality 回归修复（2026-11-07）

运行 [42350759804](https://github.com/CodeKillerCoser/codepet-remote/actions/runs/42350759804)
在 `60c2234` 上静态分析通过，测试为 438 通过、2 失败，Android 构建尚未执行。
两项失败均在本地使用原测试复现：

- 分层测试指出 `features/settings/signaling_service_settings.dart` 引用 Gateway
  adapter。`ca9e4ca` 引入该引用以捕获登记异常；现将 `SignalingRegistrationException`
  放到 `application/errors/application_failures.dart`，UI 与 adapter 都引用应用层。
  不放宽架构测试，登记文案与重试行为不变；设置测试验证具体登记错误仍可展示。
- `test/widget_test.dart` 仍假设导出结束即可出现再次分享按钮。`1dcdd68`
  已将流程改为导出后立即等待系统分享，但这个 App 级测试遗漏原生 MethodChannel
  mock，分享未完成时按钮按设计保持忙碌。现模拟分享调用及取消结果，检查 ZIP 路径、
  MIME、等待中的禁用状态和取消后的可点击性；测试结束清理 handler，不修改生产分享流程。

验证：`flutter test test/widget_test.dart test/architecture/layering_test.dart test/settings
test/gateway/device_registration_test.dart` 共 24 项通过；`flutter analyze --no-pub`
无问题，`flutter test --no-pub` 全量 440 项通过。Linux runner 和 Android debug 打包以
修复提交的 GitHub Quality 结果为准；widget mock 不代表真机分享面板验收。

回归要求：共享的可展示异常由应用层定义，界面不为获取异常类型而引用 adapter；
调用原生异步接口的 widget 测试必须控制完成结果并清理 mock。发布前的相关模块测试
不能替代 Quality 的架构与全量测试；不要通过关闭测试或取消分层限制消除失败。

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

同步时应从 CodePet 主工作区运行以下命令（假设两个仓库为相邻目录），并将 SDK 与 `cp-sdk-gen.lock.json` 一起更新：

```sh
bun tools/cp-sdk-gen/cp-sdk-gen.mjs --package gateway --role client --lang dart --protocol protocol --output ../codepet-remote/sdk/gateway
bun tools/cp-sdk-gen/cp-sdk-gen.mjs --package lan-channel --role models --lang dart --protocol protocol --output ../codepet-remote/sdk/lan
```

两条命令分别加 `--check` 可核对 Remote 的生成输出及协议摘要；CodePet 自身还需运行 `npm run protocol:check`。同为协议 v1 不代表字段相同，严格解码器会拒绝新增字段。2026-09-09 手机日志中的 `capabilities.usageDatasets: unknown field` 使三个 Provider 的能力描述整体加载失败，继而阻断最近、项目及详情的能力检查。`runtime.usage` 是独立的 Provider 用量概览，桌面在引入详情查询时误删，现已恢复完整采集转发链路及手机展示映射；不能用详情查询替代它。

同步后运行 `flutter analyze --no-pub` 及 Gateway、DeviceSession、最近和会话详情测试。`test/gateway/gateway_client_test.dart` 的公共 Provider 描述样本包含 `usageDatasets`，覆盖握手、最近、列表及详情的实际客户端解码路径。发布时仍需安装新手机包，源码同步不会更新已安装 App。

领域模型是协议的子集；适配器应显式投影 revision、methods、turnSend 和 conversationCreate，不能把包含 usageDatasets 的完整 wire 对象再交给领域模型的字段白名单。正式 SDK 已负责 wire 校验。

本次检查中，协议生成检查 20 项通过，Flutter 静态分析通过。扩大回归发现独立的既有失败：`home_recent_conversations_test.dart` 仍期待 standalone，而主分支提交 `f8328b0` 已让不支持项目的 Provider 使用 all；本次未改动该筛选行为或测试。新增 nullable 用量 DTO 的 Dart 编译问题在 CodePet 生成器修复后重新生成。客户端测试同时使用 runtime.usage 与 capabilities.usageDatasets，验证概览展示与业务能力加载可以共存。

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
