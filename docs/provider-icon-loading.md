# Provider 在线图标加载

## 现象

Gateway 已下发 Provider 的 HTTPS 图标 URL，但 Remote 在图片请求失败时显示 Codex、Claude、OpenCode 的 Material 降级符号，容易被误判为协议仍在传旧 icon token。

## 证据

- `/Applications/Code Pet.app` 内三份 `codepet-provider.json` 均包含 HTTPS icon URL。
- Remote 的 `GatewayProvider.icon` 直接映射 Gateway SDK 的 `ProviderInstance.icon`。
- Android 模拟器当时无法解析三个图标域名，默认网络 DNS 为 `10.0.2.3`，且连接未获得 `VALIDATED` capability。
- `ProviderIcon` 的图片错误分支会按 Provider identity 显示旧 Material 符号。

## 根因

截图中的符号是在线图片加载失败后的 UI 降级结果，不是 Gateway 协议数据回退。原实现使用 Flutter `NetworkImage`，只有进程内图片缓存，缺少类似 SDWebImage 的持久缓存能力；终端首次加载仍依赖可用的公网和 DNS。

## 修复方案

生产路径统一使用 `cached_network_image`，由成熟库负责 HTTP 下载、内存与磁盘缓存、并发请求复用和缓存生命周期。应用层只负责校验协议允许的 HTTPS URL，以及定义占位和错误降级 UI，不自行实现下载或文件缓存。

## 涉及模块

- `lib/features/common/identity_icons.dart`：Provider 图标的统一渲染入口。
- `pubspec.yaml`、`pubspec.lock`：声明并锁定图片缓存依赖。
- `test/features/common/identity_icons_test.dart`：验证生产路径使用缓存库，并保留 URL 安全和降级行为覆盖。

## 验证与回归防线

- `flutter analyze`。
- `flutter test test/features/common/identity_icons_test.dart`。
- `flutter test`。
- Android 真机或模拟器首次加载前确认公网 DNS 可用；断网重启应用后确认已缓存图标仍可显示。

## 未知项

- 不同终端网络对三个官方域名的可达性仍取决于用户网络环境；缓存不能替代首次下载所需的网络连接。
