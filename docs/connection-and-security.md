# 连接与安全边界

[文档导航](README.md) · [项目首页](../README.md)

CodePet Remote 只通过可替换的 channel 连接 Host Gateway，不直接连接 Codex App Server 或 Codex Desktop IPC，也不依赖 Provider 原生 DTO。

## LAN transport 边界

正式 LAN channel 优先使用已保存的 preferred WSS endpoint；连接失败时，可从前台 `_codepet._tcp.local.` 发现中选择 `deviceId` 相同且版本范围包含 v2 的候选 host/port。mDNS 只提供 endpoint 候选，不更新 TLS pin、deviceId 或其他信任信息：

- 仅接受 `wss://` URI，不降级到明文 `ws://`
- 一个 WebSocket 承载标准 JSON-RPC 2.0 request、response 和 notification
- typed method wrapper、DTO 和 event decoder 全部来自生成的 Gateway SDK；channel 不维护 method string
- 从实际 peer leaf X509 DER 计算 SHA-256，并与 QR pin 常量时间比较
- 以 Android 安全存储中的 opaque credential 发送 Bearer authorization
- TLS channel 核对 identityFingerprint；Gateway handshake 只核对 Host deviceId，并在通过后刷新 Host descriptor
- `conversation.list` 和 `conversation.get` 使用 opaque `snapshotCursor` fence 安装订阅窗口；cursor 只比较相等性，不解析或持久化
- 同一 WebSocket 订阅内按 opaque `eventCursor` 去除 replay window 内的完全重复事件，去重缓存保持有界

普通存储只保存设备 descriptor、连接身份、endpoint、TLS 指纹、clientId 与 credential key reference；credential、会话、消息、Turn、live output 和 cursor 均不写入普通持久层。项目仅按 Host 投影的 `workspaceRoot` 分组，Remote 不读取 Git/worktree 元数据。详情通过 `conversation.resume(limit=20)` 获取交互权限与首屏历史；只读回退使用 `conversation.get`。先安装返回的有序 committed snapshot，再应用 `snapshotCursor` 之后的 live output；已经由相同 `contentId` 提交的重放 delta 会被丢弃，terminal turn 只更新状态并保留输出，不重新拉取历史。首屏仅加载一页，用户手动加载更早消息时去重前插；会话数据源按 LRU 缓存，默认 8 个、闲置 15 分钟淘汰，可见数据源保留。详见[架构文档](architecture.md)。
