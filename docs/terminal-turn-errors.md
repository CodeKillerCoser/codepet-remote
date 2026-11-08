# 执行失败原因展示

2026-11-08 与 Code Pet Host 的统一终态错误契约同步。

发送请求失败仍通过 GatewayProtocolException；已接受任务的后续失败通过 TurnTask.error（code/message/retryable/details）传递。会话时间线把失败原因作为独立卡片显示，保留已有正文，无消息失败也可见；旧 Provider 回退到 displaySummary。retryable 只显示可稍后重新发送，不自动重复执行。

Gateway conversation.get 新增可选 turns，首个历史页附带 Host 记录的最近最多 100 条失败 turn，补充原生历史未保存的失败。客户端校验 Provider/会话路由，并与实时事件按 turn ID 合并；同版本没有 error 的旧副本不清掉已有错误。修复前丢失且未保存在原生历史中的原因无法恢复。

SDK 已从 Code Pet 合入队列功能后的 canonical protocol 通过 cp-sdk-gen 重新生成，包含本次 agent TurnTask.error 与 Gateway conversation.get.turns，保留已有队列接口。提交基于 Remote main ca3e80a，不包含原工作分支的 Live Updates 功能。严格旧 SDK 不能保证接受新增字段，Host、Provider 和 Remote 须协调升级。

验证：gateway_client、conversation_timeline、conversation_detail_screen、turn_failure_view 共 131 项测试通过；相关模块 analyze 通过。覆盖完整错误回读、跨路由拒绝、实时失败、旧字段 fallback、无正文、部分正文、同版本去重；320/800 宽度和 2 倍文字缩放验证布局、滚动、焦点和草稿。`flutter build apk --debug --no-pub` 构建成功，产物为 `build/app/outputs/flutter-apk/app-debug.apk`；没有替换手机上的已安装应用。
