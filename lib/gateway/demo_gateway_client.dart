import 'dart:async';

import 'gateway_client.dart';
import 'models.dart';

class DemoGatewayClient implements GatewayClient {
  DemoGatewayClient({this.profileId = 'studio'}) : _now = DateTime.now().toUtc();

  final String profileId;

  final DateTime _now;
  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast();
  final List<Timer> _timers = [];
  final Set<String> _startedStreams = {};
  int _sequence = 12;

  late final List<ConversationSummary> _conversations = profileId == 'laptop'
      ? [
          ConversationSummary(
            id: 'laptop-review',
            providerId: 'codex-demo',
            title: '检查 Android 构建',
            preview: '在独立设备会话中验证 APK',
            status: ConversationStatus.idle,
            permissionLevel: PermissionLevel.readOnly,
            workspaceRoot: '/workspace/mobile-client',
            createdAt: _now.subtract(const Duration(days: 2)),
            updatedAt: _now.subtract(const Duration(days: 1)),
          ),
          ConversationSummary(
            id: 'laptop-unscoped',
            providerId: 'codex-demo',
            title: '无项目临时会话',
            status: ConversationStatus.idle,
            permissionLevel: PermissionLevel.readOnly,
            createdAt: _now.subtract(const Duration(days: 4)),
            updatedAt: _now.subtract(const Duration(days: 3)),
          ),
        ]
      : [
    ConversationSummary(
      id: 'demo-running',
      providerId: 'codex-demo',
      title: '实现 Remote 会话流',
      preview: '正在接收 Gateway 的增量输出事件',
      status: ConversationStatus.running,
      permissionLevel: PermissionLevel.workspaceWrite,
      model: 'demo-model',
      reasoningEffort: 'medium',
      workspaceRoot: '/projects/codepet-remote',
      createdAt: _now.subtract(const Duration(hours: 1)),
      updatedAt: _now.subtract(const Duration(minutes: 1)),
      activeTurn: TurnTask(
        id: 'turn-demo',
        providerId: 'codex-demo',
        conversationId: 'demo-running',
        status: TurnStatus.running,
        displaySummary: '检查事件投影',
        startedAt: _now.subtract(const Duration(minutes: 1)),
        updatedAt: _now.subtract(const Duration(seconds: 10)),
      ),
    ),
    ConversationSummary(
      id: 'demo-idle',
      providerId: 'codex-demo',
      title: 'Gateway 协议契约核对',
      preview: '已确认 conversation.list 和 conversation.get',
      status: ConversationStatus.idle,
      permissionLevel: PermissionLevel.readOnly,
      createdAt: _now.subtract(const Duration(days: 1)),
      updatedAt: _now.subtract(const Duration(hours: 3)),
    ),
        ];

  @override
  Stream<GatewayEvent> get events => _events.stream;

  @override
  Future<GatewayHandshake> connect() async {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    return const GatewayHandshake(
      protocolVersion: gatewayProtocolVersion,
      serverName: 'CodePet Demo Host',
      serverVersion: '0.1.0-demo',
      providers: [
        GatewayProvider(
          id: 'codex-demo',
          providerType: 'codex',
          displayName: 'Codex Demo',
          status: ProviderStatus.ready,
          methods: ['conversation.list', 'conversation.get'],
        ),
      ],
      eventSequence: 12,
    );
  }

  @override
  Future<ConversationPage> listConversations({
    String? providerId,
    String? cursor,
    int limit = 50,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final conversations = _conversations
        .where((item) => providerId == null || item.providerId == providerId)
        .take(limit)
        .toList(growable: false);
    return ConversationPage(
      conversations: conversations,
      eventSequence: _sequence,
    );
  }

  @override
  Future<ConversationDetail> getConversation(
    ConversationSummary conversation,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (conversation.id == 'demo-running') {
      _scheduleStream(conversation);
      return ConversationDetail(
        summary: conversation,
        turns: [if (conversation.activeTurn != null) conversation.activeTurn!],
        messages: [
          GatewayMessage(
            id: 'demo-user',
            turnId: 'turn-demo',
            role: MessageRole.user,
            kind: 'text',
            content: '请检查 Remote Client 的事件流展示。',
            createdAt: _now.subtract(const Duration(minutes: 1)),
            isStreaming: false,
          ),
        ],
        lastEventSequence: _sequence,
      );
    }
    return ConversationDetail(
      summary: conversation,
      messages: [
        GatewayMessage(
          id: 'demo-user-idle',
          turnId: 'turn-idle',
          role: MessageRole.user,
          kind: 'text',
          content: '当前 Gateway v0 覆盖了哪些读取能力？',
          createdAt: _now.subtract(const Duration(hours: 4)),
          isStreaming: false,
        ),
        GatewayMessage(
          id: 'demo-assistant-idle',
          turnId: 'turn-idle',
          role: MessageRole.assistant,
          kind: 'text',
          content: '已覆盖会话列表、会话元数据和服务端事件。',
          createdAt: _now.subtract(const Duration(hours: 3)),
          isStreaming: false,
        ),
      ],
      lastEventSequence: _sequence,
    );
  }

  void _scheduleStream(ConversationSummary conversation) {
    if (!_startedStreams.add(conversation.id)) {
      return;
    }
    const chunks = ['事件流已连接，', '增量内容正在合并，', '展示链路工作正常。'];
    for (var index = 0; index < chunks.length; index++) {
      _timers.add(
        Timer(Duration(milliseconds: 450 + index * 550), () {
          if (_events.isClosed) {
            return;
          }
          _events.add(
            TurnOutputDeltaEvent(
              sequence: ++_sequence,
              providerId: conversation.providerId,
              conversationId: conversation.id,
              turnId: 'turn-demo',
              outputId: 'demo-output',
              kind: 'text',
              delta: chunks[index],
            ),
          );
        }),
      );
    }
    _timers.add(
      Timer(const Duration(milliseconds: 2250), () {
        if (_events.isClosed) {
          return;
        }
        _events.add(
          TurnUpsertedEvent(
            sequence: ++_sequence,
            turn: TurnTask(
              id: 'turn-demo',
              providerId: conversation.providerId,
              conversationId: conversation.id,
              status: TurnStatus.completed,
              displaySummary: '事件投影已完成',
              startedAt: _now.subtract(const Duration(minutes: 1)),
              updatedAt: DateTime.now().toUtc(),
              completedAt: DateTime.now().toUtc(),
            ),
          ),
        );
      }),
    );
  }

  @override
  Future<void> close() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    await _events.close();
  }
}
