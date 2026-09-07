# Remote 最近会话接入

R4 从 Remote `3f20065` 开始，在独立分支 `codex/recent-remote` 实现。语义设计由 Host 的 `knowledge/10-architecture/recent-conversation-feed.md` 管理；本文只记录 Remote 交付与验证边界。

## 协议与生成来源

- 协议保持 v1。R1 来源提交：`0d5d9e70d7645ebc554a98322186167f1e2b80e4`。
- 冻结契约：`C:/Users/17633/.codex/worktrees/46e4/codepet/knowledge/40-runbooks/recent-conversation-contract.md`。
- 正式 Dart 导出：`C:/Users/17633/.codex/worktrees/46e4/codepet/sdk/rust/target/recent-gateway-dart/`，同步至本仓库 `sdk/gateway/`。没有 cherry-pick Host 提交，没有手改生成文件。
- `cp-sdk-gen.lock.json`：`protocolDigest=sha256:c539baf1106a8ca2c838cb573b645a8c47a3b2efdb9660941457f16e80062d0d`，`protocolVersion=1`。
- 该导出由 R1 用 `bun tools/cp-sdk-gen/cp-sdk-gen.mjs --package gateway --role client --lang dart --protocol ./protocol --output <目录>` 正式生成。R4 仅复制其源文件，并逐文件比对 SHA256（差异 0）。Core/Agent 内容与现有版本一致。
- `conversation.recent` 通过生成的 `ProtocolClient.conversationRecent` 调用，要求 `conversation.recent` capability。`conversation.recentChanged` 经手写 mapper 转换为独立应用事件。

## 应用与首页

`RecentConversationGateway` 和 `RecentConversationController` 拥有最近成员、nextCursor、revision、加载/错误状态。Remote 不使用本地日期筛选、状态排序或普通列表缓存来推断最近。Host 返回顺序保留，仅按完整会话身份去重。

真实 adapter 对最近摘要继续校验 Provider 路由，并要求每条携带冻结契约承诺的权威 readState；缺失时明确拒绝，不能借用普通列表的默认已读值。普通 list/markRead 的既有解码和请求逻辑不变。

每次刷新先开启独立 `GatewayEventWindow`，以订阅起点和响应 `snapshotCursor` 安装 fence。revision 只比较相等，不解析。构建期间的失效、Provider generation/能力变化、重连都递增请求代次；旧异步结果不能安装或接续。过期尾页触发首屏刷新，刷新恢复期间再次过期最多自动重新开始一次；普通错误和 invalid_cursor 明确显示并等待重试。重复游标会报错。

首屏刷新先收集新快照，恢复已加载条数及可定位锚点所在页，再原子替换旧显示窗口。UI 记录第一个可见会话身份和像素位置；上方插入会话时调整 offset，锚点删除时选择后续或前面的存活相邻项。断线保留 display window 和选择的 provider ID，但丢弃旧游标。能力缺失时显示明确提示，不展示缓存结果冒充最近。

首页在滚动及布局完成后检查剩余距离，距尾部不足 240 像素时请求下一页。因此首屏不足一屏也会自动补页。只允许一个当前尾页请求；错误关闭自动续页，用户可点击“重试”。最近没有加载更多按钮。聊天/项目的既有分页入口保留。

聊天使用独立 `StandaloneConversationFilter`，项目继续使用 `ProjectConversationFilter`。recentChanged 仅由最近控制器处理，不重置普通列表的成员或游标。原有状态投影、markRead 触发和观察版本逻辑未改动。Demo 同样实现 recent port，在模拟 Gateway 内对完整数据分页；`profileId: 'recent'` 包含 125 条超过 14 天的等待输入会话。

## 代码检查与未执行项

已做：代码/逻辑/协议对照、`git diff --check`、正式导出逐文件 SHA256 比对、确认应用和首页不再引用本地 recent 筛选函数或最近加载更多入口。

新增/调整源测试覆盖：Host 顺序与身份去重、100+ 条分页、首屏不足与触底、尾页单请求、旧异步响应、请求期间事件、游标过期/错误重试、Provider generation、重连锚点、插入/删除锚点、聊天旧历史和游标隔离、生成 SDK 请求/事件/fixture、demo 完整分页。

按用户要求，所有测试、编译、构建、Flutter analyze、CI、安装及真机验证均未执行；测试代码存在不代表测试通过。页面使用已加载窗口渲染行，超大窗口的布局成本、连续失效压力和真机滚动精度仍待获准后验证。

Host 首屏返回的 fence 必须适用于本次已订阅窗口：等于窗口起点或在缓冲事件内。若 Host 复用缓存列表，不能无条件复用早于该起点的旧构建 fence；Remote 会明确报事件缺口，不猜测不透明 cursor 的顺序。R3 已确认在 snapshot mutation lock 内验证快照后捕获本次 current_event_cursor，并将首屏 fence 绑定到游标，尾页沿用；R4 已确认此方案满足窗口检查并通知 PM。
