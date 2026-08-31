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
  String get _cursor => 'demo-$_sequence';
  GatewayProviderRoute get _route => GatewayProviderRoute(
        deviceId: 'demo-$profileId',
        providerPluginId: 'dev.codepet.demo',
        providerInstanceId: 'codex-demo',
      );

  @override
  String? get latestEventCursor => _cursor;

  @override
  GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);

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
    return GatewayHandshake(
      protocolVersion: gatewayProtocolVersion,
      serverName: 'CodePet Demo Host',
      serverVersion: '0.1.0-demo',
      providers: [
        GatewayProvider(
          route: _route,
          providerType: _route.providerPluginId,
          displayName: 'Codex Demo',
          status: ProviderStatus.ready,
          methods: [
            'conversation.list',
            'conversation.search',
            'conversation.get',
          ],
        ),
      ],
      eventCursor: _cursor,
      deviceId: _route.deviceId,
      deviceDescriptor: DeviceDescriptor(
        deviceName: profileId == 'laptop' ? '演示随身电脑' : '演示工作室 Mac',
        operatingSystem: profileId == 'laptop' ? 'Android' : 'macOS',
        systemVersion: 'Demo',
      ),
    );
  }

  @override
  Future<ConversationPage> listConversations({
    required GatewayProviderRoute route,
    String? cursor,
    int limit = 50,
  }) async {
    if (route != _route) {
      throw const FormatException('Unknown demo Provider route');
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final conversations = _conversations
        .take(limit)
        .toList(growable: false);
    return ConversationPage(
      conversations: conversations,
      snapshotCursor: _cursor,
    );
  }

  @override
  Future<ConversationPage> searchConversations({
    required GatewayProviderRoute route,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  }) async {
    if (route != _route) {
      throw const FormatException('Unknown demo Provider route');
    }
    final term = searchTerm.trim().toLowerCase();
    if (term.isEmpty) {
      throw ArgumentError.value(searchTerm, 'searchTerm', 'must not be empty');
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    return ConversationPage(
      conversations: _conversations
          .where((conversation) =>
              conversation.title.toLowerCase().contains(term) ||
              (conversation.preview?.toLowerCase().contains(term) ?? false))
          .take(limit)
          .toList(growable: false),
      snapshotCursor: _cursor,
    );
  }

  @override
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) async {
    await Future<void>.delayed(const Duration(milliseconds: 160));
    if (conversation.id == 'demo-running') {
      _scheduleStream(conversation);
      return ConversationSnapshot(
        snapshotCursor: _cursor,
        detail: ConversationDetail(summary: conversation,
        turns: [if (conversation.activeTurn != null) conversation.activeTurn!],
        committedMessages: [
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
        lastEventCursor: _cursor),
      );
    }
    return ConversationSnapshot(
      snapshotCursor: _cursor,
      detail: ConversationDetail(summary: conversation,
      committedMessages: [
        GatewayMessage(
          id: 'demo-user-idle',
          turnId: 'turn-idle',
          role: MessageRole.user,
          kind: 'text',
          content: '当前 Gateway 覆盖了哪些读取能力？',
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
      lastEventCursor: _cursor),
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
              eventCursor: 'demo-${++_sequence}',
              providerId: conversation.providerId,
              conversationId: conversation.id,
              turnId: 'turn-demo',
              itemId: 'demo-item',
              contentId: 'demo-item:text',
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
            eventCursor: 'demo-${++_sequence}',
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
