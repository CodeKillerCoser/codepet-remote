# Android Live Updates（实时更新）

2026-11-08：Remote 端实现，使用已有直连设备事件，无 Host 协议改动。

## 使用

打开进行中的会话，点击右上角铃铛 →「关注当前任务」。开始前强制刷新会话，申请普通通知权限。一次只关注一个明确的 turn；关注另一任务会替换之前的持续通知，不影响任务执行。默认不开启关注，不根据其他设备的活动自动抢占。

持续通知展示运行、排队、待授权、待补充输入及可选摘要，无虚构百分比。预览默认关闭，开启时沿用通知内容预览偏好及 PRIVATE 锁屏可见性。持续通知完全静默；待处理事件和最终结果的响铃、当前页面抑制、去重和中断行为继续由原 NotificationCoordinator 决定。

点击只导航，先经现有 getConversation 权威刷新，然后加载会话并定位 request/turn；已过期审批显示现有提示。点击不审批、不停止任务。取消关注按钮与用户划除都只撤掉持续展示。原生持久记录划除，后续事件不能重新上岛；明确再次选择关注才可恢复。应用重启不自动恢复关注。

## 平台实现

- AndroidX Core 1.17.0 的 NotificationCompat，BigTextStyle，ongoing、contentTitle、小图标、LOW channel、onlyAlertOnce、silent；无自定义 RemoteViews、group summary 或 colorized。
- Manifest 声明 POST_PROMOTED_NOTIFICATIONS；API 36+ 通过 setRequestPromotedOngoing 请求提升并设置简短状态。
- flutter_local_notifications 22.3.3 的当前 AndroidNotificationDetails 未提供上述提升接口，因此通过独立 Kotlin MethodChannel 补齐；原普通通知不迁移。
- 查询通知总权限、通道权限、canPostPromotedNotifications 与实际活动通知的 FLAG_PROMOTED_ONGOING。关注对话框分别显示资格与实际提升情况，提供系统设置入口；系统不支持专用设置时退回应用通知设置。
- API 36 以下仍使用普通持续通知。权限拒绝不发通知，业务事件不受影响；不允许提升仍发普通持续通知。没有厂商品牌判断，不保证 vivo 原子岛。

## 状态与边界

LiveUpdateCoordinator 串行处理一个 device/provider/conversation/turn 身份，拒绝其他设备/turn 与较旧版本；resolved/cancelled/expired request 留内存 tombstone，防止 replay 恢复待审批。完成、失败、中断都结束活动；结果策略不变。新 activeTurn 不会自动获得关注。

无新状态三分钟后结束关注，原生通知也带三分钟 timeout，避免进程死后无限展示。长时间无事件的合法任务可能因此消失，需用户刷新并重新关注。断网不会凭旧缓存推断成功；最多保留上述窗口。此超时不是服务器心跳，也不代表任务停止。

后台可选 connectedDevice 前台服务只延续现有连接，不是云推送。进程被终止、设备断网或 Host 不可达时无法保证及时更新/提醒。没有增加云推送、厂商场景申请或 iOS 工程。当前协议无数值进度；关键摘要取 TurnTask.displaySummary。

## 验证

- `flutter analyze --no-pub`
- `flutter test --no-pub test/notifications test/architecture`
- `flutter build apk --debug --no-pub`
- `python3 tool/run_live_update_probe.py --device emulator-5554`：自动授权、点击并取消关注；加 `--swipe` 验证设备的系统划除行为。
- `flutter test --no-pub -d emulator-5554 integration_test/live_updates_test.dart --dart-define=LIVE_DISMISS_PROBE=true`：隔离模拟器先授权 POST_NOTIFICATIONS；日志出现 LIVE_READY_FOR_DISMISS 后在通知栏点取消关注（20 秒内）。

2026-11-08：静态分析无问题，29 项通知/架构测试通过，原生集成探针通过（系统授权、通知点击精确身份、取消关注后防重发）。Android 36 模拟器实测：普通持续通知发出；运行→待审批更新同一 ID；取消关注后再次 show 返回 false、不重发；取消清理成功。实际能力：supported=true、allowed=true、promotionAllowed=false、promoted=false。因此已验证降级路径，**未验证系统 chip 提升成功**。追加点击探针已确认 device/turn/request 身份传递正确。横向划除探针未通过：该镜像上的手势未移除 ongoing 通知，再次 show 仍返回 true；不能据此宣称系统划除路径已实测通过。原生 deleteIntent 与取消关注共用持久 tombstone 接收器。API 24–35 真机、OEM 锁屏/chip、真机网络中断和系统杀进程仍需设备回归；不能把单元状态测试等同于真机审批或推送验证。

状态测试覆盖主动关注、默认隐私、运行→审批→恢复→完成/失败/中断、输入等待、乱序、跨设备、切换任务、过期、用户取消/权限关闭后的不重发、当前会话可见时持续展示而抑制提醒，以及既有路由/去重测试。

试用包：`artifacts/codepet-remote-live-updates-debug.apk`（仓库公开 debug 签名，不是 release）。

## 官方参考

- [Live Updates 要求、用户主动关注与撤销](https://developer.android.com/develop/ui/views/notifications/live-update)
- [AndroidX NotificationCompat](https://developer.android.com/reference/androidx/core/app/NotificationCompat)
- [Android 16 QPR2 原生实现](https://android.googlesource.com/platform/frameworks/base/+/android16-qpr2-release/core/java/android/app/Notification.java)
