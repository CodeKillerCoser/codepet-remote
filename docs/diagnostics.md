# 日志与离线 Trace 分析

[文档导航](README.md) · [项目首页](../README.md)

## Android 导出与分享

在「App 设置 → 导出并分享诊断日志」生成 ZIP 后，立即调用系统分享面板，可选择微信等已安装应用。取消或分享失败会保留生成的 ZIP；同一行的分享图标可再次分享，不必重新导出。生成或分享进行中禁止重复操作。系统返回的分享结果只说明面板交互状态，不代表对方已收到文件。

2026-11-06 排查发现，旧 `_export()` 只生成文件并提示成功，分享按钮在页面末尾另起一行。通知设置增加后，导出路径和分享按钮容易落到可视区域之外。代码没有删掉 share_plus，但用户仍需寻找第二个入口；此前是否还有其他真机故障，缺少手机日志，尚未确认。

回归检查：`flutter test test/settings/app_settings_screen_test.dart test/diagnostics`，14 项通过。覆盖真实 Dart 分享插件的原生 MethodChannel 参数（ZIP 路径、MIME）、360×640 且通知设置展开时的按钮可点击性、取消重试、分享异常、导出异常、重复点击，以及日志轮转和 ZIP 内容。相关两个 Dart 文件的 `flutter analyze` 无问题。

原生验收：Android API 36 模拟器先安装旧 Release `02232dc`，复现导出后分享按钮被推到屏外；继续向下滚动后，旧按钮仍能打开系统面板。随后覆盖安装 GitHub Actions `42088973117` 的正式签名 Release `1dcdd68`：一次点击导出即进入 `com.android.intentresolver/.ChooserActivityLauncher`，显示一个日志 ZIP；返回后同一行的分享图标可见，再次点击仍分享同一个 ZIP。签名与上一版一致，VPS 下载的 APK 和 ZIP 整包 SHA-256 校验一致。模拟器没有微信，实际发送给电脑仍需手机验收。

## 离线 Trace 分析

Remote 和支持 `trace-context-v1` 的 Host 会输出 `codepet.trace.v1` JSONL。Remote 的日志导出 zip 可以直接作为分析输入；Host 侧保存标准错误输出中的 JSON 行即可。工具按 `traceId` 合并多个端的时间线：

```sh
dart run tool/trace_analyzer.dart remote-logs.zip host.jsonl
dart run tool/trace_analyzer.dart --trace <32位trace-id> remote-logs.zip host.jsonl
```

时间线覆盖用户发送、Gateway client RPC、Host 接收/完成、首个 turn output event、移动端 timeline 投影和首帧渲染。协议元数据和日志不包含 prompt、输出正文或 credential。跨设备排序依赖系统 UTC 时钟；若两个设备时钟未同步，以各端自身 `durationUs` 为准，并用同一 RPC 的收发边界辅助判断网络段，不直接把负间隔解释为性能结论。
