# Host 地址变化后的自动恢复

## 现象

已配对 Remote 保存了 Host 上一次成功连接的 Gateway URL。Host 经过 DHCP、Wi-Fi 或默认路由变化后，即使 Host 已在固定端口重新发布新地址，Remote 仍可能长时间显示连接失败。

## 证据

- `lib/discovery/resolving_gateway_transport.dart` 原先依次尝试持久化 endpoint、同 IP 的固定端口，全部失败后才进行一次 mDNS 搜索。
- `lib/discovery/codepet_discovery.dart` 原先每次调用只创建一个最长四秒的查询窗口，没有维护按 Host 身份索引的长期发现状态。
- Host 现场日志在网络切换期间出现 `remote_lan_route_probe_failed` 和 mDNS announce timeout；随后本机 DNS-SD 已可把相同 Host `deviceId` 解析到新 IPv4，说明 Host 与 Remote 的恢复时序仍可能错开。

## 根因

Remote 把发现当成单次连接 fallback，而不是设备生命周期输入。重连优先消耗旧 IP 的超时窗口，Host 新 generation 即使已出现，也不能立即更新当前候选或唤醒处于退避中的 session。

## 引入历史

`178413a` 增加了连接失败后的 mDNS fallback，`02a1fc0` 为每个候选增加有界超时；两者解决了无限挂起，但仍保留了短时、按连接调用发现的模型。

## 修复方案

- App composition root 持有单个 `MdnsCodePetHostDirectory`，在 App 生命周期内持续执行发现，避免每个设备各自维护扫描器。
- 目录按 mDNS TXT `id` 索引 Host，用短期 freshness 淘汰过期 endpoint；相同记录只刷新时间，不发送重复变化事件。
- Gateway resolver 优先尝试目录中的新鲜 endpoint，并在旧候选失败后再次读取目录；只有没有共享目录的测试或兼容调用继续使用单次发现。
- `DeviceSession` 订阅对应 Host 的变化。只有最近一次失败可重试时才取消退避并立即重连；认证拒绝和身份错误保持 fail closed。
- 发现地址仍只作为候选。正式连接继续验证已保存的 TLS 指纹、credential 和 Gateway handshake，不信任 mDNS 名称或地址本身。

## 涉及模块

- `lib/discovery/codepet_discovery.dart`：持续发现目录、身份索引、freshness 和生命周期。
- `lib/discovery/resolving_gateway_transport.dart`：新鲜发现候选的连接优先级与兼容 fallback。
- `lib/application/sessions/device_session.dart`：发现变化唤醒 retryable failure，同时隔离非重试错误。
- `lib/app/codepet_remote_app.dart`：共享目录的创建、注入和释放。

## 验证结果

- 定向测试覆盖 `deviceId` 不变时 A→B 替换、候选过期、B 优先于持久化 A、发现唤醒和 credential 拒绝隔离。
- App widget 测试覆盖共享目录随 App 创建和释放。
- 仍需 Android 真机执行 Wi-Fi 断开/重连、DHCP 地址变化和后台恢复 smoke；模拟器 host alias 不能代替真实 mDNS 验证。

## 回归防线

发现、连接和信任继续保持三层：发现提供有期限候选，连接选择当前 endpoint，TLS pin、credential 与 handshake 决定是否可信。任何新的自动连接路径都必须覆盖地址变化和非重试认证失败。

## 规约候选

Host 与 Remote 的长期约束已同步到 Code Pet `knowledge/60-rules/remote-lan-runtime-address-generation.md`。

## 未知项

- 当前持续目录仍复用 Flutter `multicast_dns` 和 Android multicast lock；迁移到 Android `NsdManager` 与 iOS Network framework 需要独立真机验证。
- 不同 VLAN、访客 Wi-Fi、AP client isolation 或 App 被系统杀死时，纯 LAN 发现无法保证恢复。
