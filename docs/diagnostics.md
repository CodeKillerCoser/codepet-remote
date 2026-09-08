# 日志与离线 Trace 分析

[文档导航](README.md) · [项目首页](../README.md)

Remote 和支持 `trace-context-v1` 的 Host 会输出 `codepet.trace.v1` JSONL。Remote 的日志导出 zip 可以直接作为分析输入；Host 侧保存标准错误输出中的 JSON 行即可。工具按 `traceId` 合并多个端的时间线：

```sh
dart run tool/trace_analyzer.dart remote-logs.zip host.jsonl
dart run tool/trace_analyzer.dart --trace <32位trace-id> remote-logs.zip host.jsonl
```

时间线覆盖用户发送、Gateway client RPC、Host 接收/完成、首个 turn output event、移动端 timeline 投影和首帧渲染。协议元数据和日志不包含 prompt、输出正文或 credential。跨设备排序依赖系统 UTC 时钟；若两个设备时钟未同步，以各端自身 `durationUs` 为准，并用同一 RPC 的收发边界辅助判断网络段，不直接把负间隔解释为性能结论。
