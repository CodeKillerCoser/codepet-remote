# WebRTC 通道开发状态

2026-11-06：开启 WebRTC 后，并行竞速 LAN/WSS、IPv6 直连、IPv4 直连和 TURN 中继；先建立者获胜。
文件挂载、上传下载和预览不在本轮范围。

## 使用

先按既有 LAN 流程配对，在首页菜单进入 App 设置，打开“开启 WebRTC”，
完全退出并重新打开 App。设置页“当前通道：WebRTC”表示此次启动选用了 RTC。
组合入口选择 RoutedRtcTransport，由通道层并行建立四种路径；GatewayClient、业务方法不判断路由。
开关默认关闭，关闭后重启恢复 LAN/WSS。旧设备记录、TLS pin、credential 不迁移。
设置替代原 CODEPET_WEBRTC 编译期开关，普通 Debug/Release 构建均可在 App 内选择。
lib/app/channel_preferences.dart 负责持久化，main.dart 在启动前读取；
设置页只保存下次启动的值，组合入口本次启动的选择保持不变，重连也不会提前切换。
保存失败保留原开关状态并提示重试。开启后 LAN/WSS 也是竞速候选，设置页的 WebRTC 表示启用了此连接模式，不代表本次实际选中 RTC。

验收需安装本轮包含公网接入的 Host 与 Remote；旧版 LAN RTC 包不包含公网授权升级。
打开开关重启后连接已配对设备，验证会话列表、请求和事件；再关闭重启验证 LAN。
仅把 App 切到后台不算重启。手机验收和覆盖安装需使用固定 Debug 签名的 APK。

首次在 LAN 连接时，使用原 TLS pin 和 bearer 完成 `/remote/v1/channel-bootstrap`，
把设备签名私钥和独立信令 token 保存在安全存储。退出 LAN 后可通过公网信令连接。
当前部署地址为 https://172.96.254.12:8443；地址由可信 bootstrap 下发，不硬编码进业务层。
不要求注册账号。签名验证绑定 host/client/attempt/expiry/offerHash 和 SDP，业务 bearer 不交给云端。
保留 `/remote/v1/webrtc/offer` 兼容旧 LAN RTC 客户端；新竞速的 LAN 路径使用 WSS。云端故障不影响已健康连接的数据通道。
只有中继赢家在 TURN 凭据到期前受控重连；直连不受 TURN 凭据续期影响。不自动重放业务写请求。日志记录赢家 lan / ipv6-direct / ipv4-direct / relay，RTC 诊断保留实际候选对。

## 并行竞速

- LAN 与安全存储加载同时开始；已有公网授权就同时启动三个独立 peer。LAN 总预算 8 秒、每个 RTC 55 秒，未串行叠加。
- 每个 peer 的签名 offer/answer 包含 `pathPolicy`；新 Remote 要求 Host 回显完全相同的策略。无字段的旧客户端仍可连接新 Host；新 Remote 的云端路径需要同步更新 Host。
- IPv6 只交换 IPv6 非中继候选；IPv4 只配置 STUN、只交换 IPv4 非中继候选；中继只配置 TURN、强制 relay。IPv6 不依赖 VPS 有 IPv6 地址。
- 首个连接成功后即返回，关闭其他 peer、HTTP 信令、订阅和候选定时器。落败尝试的事件与错误不进入业务会话；迟到成功不能替换赢家。
- 同一时刻只让赢家承载业务；通道建立后不因后来的更快链路而自动迁移。网络断开后由原会话重连逻辑重新竞速，不重放写请求。
- 每条路径各自校验身份；某一路径认证失败不降低其他路径的认证要求。没有赢家时保留不可重试错误，而非无限重试。
- `routed_rtc_transport_test.dart` 覆盖四路各自先成功、超时、取消、迟到成功、RPC 唯一发送和错误隔离；`rtc_path_policy_test.dart` 覆盖候选隔离和 ICE 配置。

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

公网增量：最终 Gateway/设置/App/分层测试 107 项通过；Debug APK 构建成功且仍用仓库固定
签名。Host Windows 双 peer 强制 TURN/UDP 探针已验证 VPS 中继、大消息与撤销。
Android 公网探针 APK 构建成功，但手机锁定导致 ADB 安装等待，测试尚未运行。
Rust webrtc-ice 0.14.0 仅实现 TURN/UDP；桌面端 TURN/TCP/TLS 尚不支持，不作兜底承诺。

设置入口增量验证（2026-09-09）：flutter test test/settings test/app test/architecture
共 13 项通过，覆盖默认 LAN、保存后当前通道不变、重开读取、关闭恢复和保存失败；
360×800 逻辑尺寸无布局异常，相关 5 个文件 flutter analyze 无问题。
flutter build apk --debug 成功，固定签名核验一致，adb install -r 成功。
RMX3366 实际打开开关后 force-stop/relaunch，设置仍开启且显示“当前通道：WebRTC”；
截图检查文字和动作完整可见。此轮手机尚无配对设备，未重新执行真实业务连接验收。

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

## 2026-11-06 竞速增量验收

Gateway/发现/App/架构/设置 152 项回归通过，新增竞速取消修订后定向测试再次通过；相关 flutter analyze 无问题，Debug APK 构建成功。Host 76 项单测和 3 项 LAN/RTC 集成测试通过，桌面 Tauri lib 编译检查通过。
正式 VPS 已部署多 attempt 信箱支持。独立临时身份的 Rust 原生探针分别验证实际 IPv6、IPv4 直连及双方均 relay 的 TURN/UDP 中继，均通过业务握手、大消息和撤销。两端 peer 同在一台 Mac，不能替代手机跨网 NAT 验收。本轮没有替换桌面安装版或安装手机 APK。

## 剩余交付

大陆手机实际跨网络验收、TURN TCP/TLS 分支、网络切换及临时凭据到期恢复仍待实测。
VPS 上信令/coturn 已启动，IP 证书自动续期模拟通过，原有 xray 443 服务保留。
部署与协议细节见 Host `knowledge/40-runbooks/webrtc-public-signaling.md`。


## 并行竞速日志（2026-11-06 补充）

每次连接使用 raceId 关联四路尝试；每条 RTC 路径的 transport 与 signaling 共用 connectionId，通过 offerId/attempt 对齐 Host/VPS。诊断记录每路开始、预算、失败阶段、耗时、选中结果与正常取消原因；鉴权、无候选、HTTP、TLS 和超时有受控原因分类，不输出异常原文或完整 SDP。

真实文件写入及日志 ZIP 导出回归已验证关联字段和取消结果。实机失败后请尽快从设置导出日志，并记录复现时间、网络和 VPN 状态；日志容量约 10 MiB，反复测试可能覆盖较早记录。两端必须安装包含本轮改动的新构建；库未暴露的底层 ICE 错误码仍不可从应用日志获得。
