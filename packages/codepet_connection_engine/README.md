# CodePet Connection Engine

独立 Dart 连接引擎，负责通道选择、健康观测和传输统计。运行时依赖只有 Dart 标准库；不依赖 Flutter、Gateway、Provider、Android、文件系统或网络库。应用仅通过适配器提供连接与交接操作。

## 独立验证

需要 Dart 3.13.2 或兼容版本。在本目录执行，既不需要启动 App，也不需要账号、手机、信令或 VPS：

```sh
dart pub get
dart analyze --fatal-infos
dart test
dart run tool/stress.dart 10000 16
```

最后两个参数分别是循环次数、并发模拟设备数（1–256）。压力脚本混合建立、硬故障恢复、优先级升级与断开；每批都断言资源回收。输出纯文本，包含 ready/recovery/upgrade/cleanup 的耗时、峰值进程 RSS、剩余连接、候选许可和排队数。异常会以非零退出码结束。CI 中有独立的 `connection-engine` 作业，直接安装 Dart，压力报告作为 `connection-engine-stress` 产物保存。

这些数字是纯引擎与模拟适配器的调度开销，**不是** ICE 耗时、网络带宽或手机 CPU/RSS。RSS 包含 Dart VM、测试适配器、结果数组及 GC。原生传输和真实网络需要另外验收。

## 接口与责任

- `ConnectionEngine.reconcile(ConnectionTarget)`：幂等地保持目标可用。输入是设备身份、授权版本、环境版本、允许的候选和优化预算，不包含“切网/前台/重连”等场景分支。
- `CandidateRoute.open(Cancellation)`：完成身份校验和准备后返回连接，尚不接纳业务。四路并行；同批就绪按 LAN → IPv6 → IPv4 → relay 选择。企业 VPN/Tailscale 由外层提供普通 LAN 路径。
- `ConnectionHandover.activate`：适配器负责排空业务、对端权威确认和事件恢复。`false` 只表示旧通道仍然有效；结果未知必须先向对端确认，不能猜测回滚。已发送的业务写操作不得重放。
- `PreparedConnection`：提供健康事件、有界探测和物理连接计数。`close` 必须幂等并释放原生资源；迟到的 open 结果也会关闭。取消令牌须传给实际 IO，不能只取消 Dart 等待。open 抛错前须清理已分配资源；若不能证明清理完成，抛出 `ConnectionFailure(unreleasedResources: true)` 隔离许可。
- `changes/snapshot`：当前活动连接、阶段、健康、优化状态和流量，状态即时发布、速率每秒采样。每条物理连接重新计数，候选的流量不混入活动连接。
- `disconnect/dispose`：先隔离代次，再有界等待清理。dispose 立即禁止重新启动。

全局候选默认 8；排队恢复优先于健康路径优化，同优先级 FIFO。已经开始的原生 IO 不靠逻辑释放许可假装完成。每个目标每轮最多四条候选；积压清理达到保护阈值后停止新增。无法完成或失败的 native close 会占用隔离资源，防止反复失败造成无限分配；诊断会明确记录 `cleanup_failed_quarantined`，这类适配器故障可能需要重启进程释放预算。

默认稳定窗口 2 秒、升级冷却 15 秒。失败重试从 2 秒开始指数退避，优化复查从 30 秒开始，均有抖动、上限 60 秒；新环境输入可提前唤醒。`optimize: false` 保留活动连接、健康检查及故障恢复，停止健康连接的后台择优。空候选不产生循环定时器。

流量用 30 个 100ms 桶计算三秒窗口速率。`TrafficMeter` 使用单调时钟，可以注入假时钟；空闲速率归零而累计量保持。业务/传输字节口径由适配器确定，不能当运营商账单。

## 测试覆盖与适配器验收

核心测试包含取消/超时/迟到结果、重复输入、优先级收敛、授权撤销、排空失败、确认不明、全局预算、后台预算、native 清理失败、计数归属与 1,000 次资源清零循环。测试通过公开端口注入故障，不 mock App 业务控制器。

App 桥接位于 `../../lib/gateway/connection/`；其测试是 `../../test/gateway/engine_gateway_transport_test.dart`。Host 的 `remote_lan_listener` 测试通过真实 TLS/WSS 和原生 WebRTC 验证能力协商、prepared/active、跨通道切换和旧代拒绝。完整流程与尚未做的实机验证见 CodePet 仓库 `knowledge/10-architecture/connection-engine.md`。
