import 'dart:async';

import '../core/domain/models.dart';
import '../application/ports/gateway_client.dart';
import '../application/sync/gateway_event_window.dart';

class DemoGatewayClient implements GatewayClient, ProjectGatewayClient {
  DemoGatewayClient({this.profileId = 'studio'}) : _now = DateTime.now().toUtc();

  final String profileId;

  final DateTime _now;
  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast();
  final List<Timer> _timers = [];
  final Set<String> _startedStreams = {};
  final Map<String, List<GatewayMessage>> _sentHistory = {};
  final Map<String, TurnTask> _activeTurns = {};
  int _sequence = 12;
  String get _cursor => 'demo-$_sequence';
  GatewayProviderRoute get _route => GatewayProviderRoute(
        deviceId: 'demo-$profileId',
        providerPluginId: 'dev.codepet.demo',
        providerInstanceId: 'codex-demo',
      );

  late final List<GatewayProject> _projects = [
    GatewayProject(
      resource: _projectResource(
        profileId == 'laptop' ? 'mobile-client' : 'codepet-remote',
      ),
      name: profileId == 'laptop' ? 'mobile-client' : 'codepet-remote',
      roots: [
        ProjectRoot(
          path: profileId == 'laptop'
              ? '/workspace/mobile-client'
              : '/projects/codepet-remote',
        ),
      ],
      metadata: const {},
      position: 0,
      createdAt: _now.subtract(const Duration(days: 30)),
      updatedAt: _now.subtract(const Duration(minutes: 1)),
    ),
  ];

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
            project: _projects.first.resource,
            createdAt: _now.subtract(const Duration(days: 2)),
            updatedAt: _now.subtract(const Duration(days: 1)),
            resource: _conversationResource('laptop-review'),
          ),
          ConversationSummary(
            id: 'laptop-unscoped',
            providerId: 'codex-demo',
            title: '无项目临时会话',
            status: ConversationStatus.idle,
            permissionLevel: PermissionLevel.readOnly,
            createdAt: _now.subtract(const Duration(days: 4)),
            updatedAt: _now.subtract(const Duration(days: 3)),
            resource: _conversationResource('laptop-unscoped'),
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
      project: _projects.first.resource,
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
      resource: _conversationResource('demo-running'),
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
      resource: _conversationResource('demo-idle'),
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
          harness: const HarnessDescriptor(
            id: 'demo-harness',
            displayName: 'Demo Harness',
            version: '1.0.0',
          ),
          capabilities: const GatewayCapabilities(
            revision: 'demo-capabilities-1',
            methods: [
              'project.list',
              'project.get',
              'project.create',
              'project.update',
              'project.delete',
              'conversation.list',
              'conversation.search',
              'conversation.get',
              'conversation.create',
              'turn.send',
            ],
            turnSend: TurnSendCapabilities(
              accessMode: ProviderChoiceSet(
                options: [
                  ProviderChoice(
                    id: 'read-only',
                    displayName: '只读',
                    description: '只读取当前工作区',
                  ),
                  ProviderChoice(
                    id: 'workspace-write',
                    displayName: '工作区写入',
                    description: '允许修改当前工作区',
                  ),
                ],
                defaultId: 'workspace-write',
              ),
              reasoningEffort: ProviderChoiceSet(
                options: [
                  ProviderChoice(id: 'medium', displayName: '中等'),
                  ProviderChoice(id: 'high', displayName: '高'),
                ],
                defaultId: 'medium',
              ),
              modelCatalog: FlatModelCatalog(
                models: [
                  ProviderChoice(
                    id: 'demo-fast',
                    displayName: 'Demo Fast',
                  ),
                  ProviderChoice(
                    id: 'demo-deep',
                    displayName: 'Demo Deep',
                  ),
                ],
                defaultSelection: FlatModelSelection(
                  modelId: 'demo-fast',
                ),
              ),
            ),
          ),
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
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    if (route != _route) {
      throw const FormatException('Unknown demo Provider route');
    }
    await Future<void>.delayed(const Duration(milliseconds: 180));
    final conversations = _conversations
        .where((conversation) => switch (projectFilter) {
              AllConversationFilter() => true,
              StandaloneConversationFilter() => conversation.project == null,
              ProjectConversationFilter(:final project) =>
                conversation.project == project,
            })
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
        turns: [
          if (_activeTurns[conversation.id] != null)
            _activeTurns[conversation.id]!
          else if (conversation.activeTurn != null)
            conversation.activeTurn!,
        ],
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
          ...?_sentHistory[conversation.id],
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
        ...?_sentHistory[conversation.id],
      ],
      lastEventCursor: _cursor),
      );
  }

  @override
  Future<ConversationInteraction> acquireInteraction(
    ConversationSummary conversation,
  ) async =>
      ConversationInteraction(
        selection: conversation.turnSendSelection ??
            const TurnSendSelection(),
      );

  @override
  Future<ConversationSummary> createConversation({
    required GatewayProviderRoute route,
    String? title,
    required String permissionLevel,
    String? model,
    String? reasoningEffort,
    String? workspaceRoot,
    String? workspaceMode,
    RoutedResourceId? project,
  }) async {
    if (route != _route) {
      throw const FormatException('Unknown demo Provider route');
    }
    final now = DateTime.now().toUtc();
    final id = 'demo-created-${++_sequence}';
    final conversation = ConversationSummary(
      id: id,
      providerId: _route.providerInstanceId,
      title: title ?? '新会话',
      status: ConversationStatus.idle,
      permissionLevel: permissionLevel,
      model: model,
      reasoningEffort: reasoningEffort,
      workspaceRoot: workspaceRoot,
      project: project,
      createdAt: now,
      updatedAt: now,
      resource: _conversationResource(id),
    );
    _conversations.insert(0, conversation);
    _events.add(ConversationUpsertedEvent(
      eventCursor: 'demo-${++_sequence}',
      conversation: conversation,
    ));
    return conversation;
  }

  @override
  Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) async {
    if (route != _route || capabilityRevision != 'demo-capabilities-1') {
      throw const FormatException('Demo turn.send capability is stale');
    }
    if (text.trim().isEmpty || _activeTurns[conversation.id] != null) {
      throw const FormatException('Demo conversation cannot accept this turn');
    }
    final now = DateTime.now().toUtc();
    final turnId = 'demo-turn-${++_sequence}';
    final turn = TurnTask(
      id: turnId,
      providerId: _route.providerInstanceId,
      conversationId: conversation.id,
      status: TurnStatus.queued,
      updatedAt: now,
      clientRequestId: clientRequestId,
    );
    final input = GatewayMessage(
      id: 'demo-input-$clientRequestId',
      turnId: turnId,
      role: MessageRole.user,
      kind: 'message',
      content: text,
      createdAt: now,
      isStreaming: false,
    );
    _sentHistory.putIfAbsent(conversation.id, () => []).add(input);
    _activeTurns[conversation.id] = turn;
    _scheduleSentTurn(conversation, turn, text);
    return TurnSendReceipt(
      clientRequestId: clientRequestId,
      turn: turn,
      inputItem: input,
      effectiveSelection: selection,
    );
  }

  void _scheduleSentTurn(
    ConversationSummary conversation,
    TurnTask turn,
    String text,
  ) {
    const chunks = ['已收到：', '正在处理，', '演示回复完成。'];
    for (var index = 0; index < chunks.length; index++) {
      _timers.add(Timer(Duration(milliseconds: 250 + index * 350), () {
        if (_events.isClosed) return;
        _events.add(TurnOutputDeltaEvent(
          eventCursor: 'demo-${++_sequence}',
          providerId: conversation.providerId,
          conversationId: conversation.id,
          turnId: turn.id,
          itemId: '${turn.id}-assistant',
          contentId: '${turn.id}-assistant:text',
          kind: 'text',
          delta: chunks[index],
        ));
      }));
    }
    _timers.add(Timer(const Duration(milliseconds: 1450), () {
      if (_events.isClosed) return;
      final completed = TurnTask(
        id: turn.id,
        providerId: turn.providerId,
        conversationId: turn.conversationId,
        status: TurnStatus.completed,
        updatedAt: DateTime.now().toUtc(),
        completedAt: DateTime.now().toUtc(),
        clientRequestId: turn.clientRequestId,
      );
      _activeTurns.remove(conversation.id);
      _sentHistory.putIfAbsent(conversation.id, () => []).add(
        GatewayMessage(
          id: '${turn.id}-assistant',
          turnId: turn.id,
          role: MessageRole.assistant,
          kind: 'message',
          content: '${chunks.join()}\n$text',
          createdAt: completed.updatedAt,
          isStreaming: false,
          contentIds: ['${turn.id}-assistant:text'],
        ),
      );
      _events.add(TurnUpsertedEvent(
        eventCursor: 'demo-${++_sequence}',
        turn: completed,
      ));
    }));
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
        final completedAt = DateTime.now().toUtc();
        final completed = TurnTask(
          id: 'turn-demo',
          providerId: conversation.providerId,
          conversationId: conversation.id,
          status: TurnStatus.completed,
          displaySummary: '事件投影已完成',
          startedAt: _now.subtract(const Duration(minutes: 1)),
          updatedAt: completedAt,
          completedAt: completedAt,
        );
        _sentHistory.putIfAbsent(conversation.id, () => []).add(
          GatewayMessage(
            id: 'demo-item',
            turnId: completed.id,
            role: MessageRole.assistant,
            kind: 'message',
            content: chunks.join(),
            createdAt: completedAt,
            isStreaming: false,
            contentIds: const ['demo-item:text'],
          ),
        );
        final updatedConversation = _withoutActiveTurn(conversation);
        final conversationIndex = _conversations.indexWhere(
          (candidate) => candidate.id == conversation.id,
        );
        if (conversationIndex != -1) {
          _conversations[conversationIndex] = updatedConversation;
        }
        _events.add(ConversationUpsertedEvent(
          eventCursor: 'demo-${++_sequence}',
          conversation: updatedConversation,
        ));
        _events.add(
          TurnUpsertedEvent(
            eventCursor: 'demo-${++_sequence}',
            turn: completed,
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

  RoutedResourceId _conversationResource(String id) => RoutedResourceId(
        route: _route,
        nativeResourceId: id,
      );

  RoutedResourceId _projectResource(String id) => RoutedResourceId(
        route: _route,
        nativeResourceId: id,
      );

  ConversationSummary _withoutActiveTurn(ConversationSummary conversation) =>
      ConversationSummary(
        id: conversation.id,
        providerId: conversation.providerId,
        title: conversation.title,
        preview: conversation.preview,
        status: ConversationStatus.idle,
        permissionLevel: conversation.permissionLevel,
        model: conversation.model,
        reasoningEffort: conversation.reasoningEffort,
        workspaceRoot: conversation.workspaceRoot,
        project: conversation.project,
        createdAt: conversation.createdAt,
        updatedAt: DateTime.now().toUtc(),
        turnSendSelection: conversation.turnSendSelection,
        resource: conversation.resource,
      );

  @override
  Future<ProjectPage> listProjects({
    required GatewayProviderRoute route,
    String? cursor,
    int limit = 50,
  }) async {
    if (route != _route) {
      throw const FormatException('Unknown demo Provider route');
    }
    return ProjectPage(
      projects: _projects.take(limit).toList(growable: false),
      snapshotCursor: _cursor,
    );
  }

  @override
  Future<GatewayProject> getProject(RoutedResourceId project) async =>
      _projects.firstWhere((candidate) => candidate.resource == project);

  @override
  Future<GatewayProject> createProject({
    required GatewayProviderRoute route,
    required String idempotencyKey,
    required String name,
    required List<ProjectRoot> roots,
    Map<String, String> metadata = const {},
  }) async {
    if (route != _route) {
      throw const FormatException('Unknown demo Provider route');
    }
    final now = DateTime.now().toUtc();
    final project = GatewayProject(
      resource: _projectResource('demo-project-${++_sequence}'),
      name: name,
      roots: roots,
      metadata: metadata,
      position: _projects.length,
      createdAt: now,
      updatedAt: now,
    );
    _projects.add(project);
    _emitProjectChange(project.resource, ProjectChangeType.created);
    return project;
  }

  @override
  Future<GatewayProject> updateProject({
    required RoutedResourceId project,
    String? name,
    List<ProjectRoot>? roots,
    Map<String, String>? metadata,
  }) async {
    final index = _projects.indexWhere((item) => item.resource == project);
    if (index == -1) throw StateError('Unknown demo project');
    final current = _projects[index];
    final updated = GatewayProject(
      resource: current.resource,
      name: name ?? current.name,
      roots: roots ?? current.roots,
      metadata: metadata ?? current.metadata,
      position: current.position,
      createdAt: current.createdAt,
      updatedAt: DateTime.now().toUtc(),
    );
    _projects[index] = updated;
    _emitProjectChange(project, ProjectChangeType.updated);
    return updated;
  }

  @override
  Future<void> deleteProject(RoutedResourceId project) async {
    _projects.removeWhere((item) => item.resource == project);
    _emitProjectChange(project, ProjectChangeType.deleted);
  }

  void _emitProjectChange(
    RoutedResourceId project,
    ProjectChangeType changeType,
  ) {
    _events.add(ProjectChangedEvent(
      eventCursor: 'demo-${++_sequence}',
      project: project,
      changeType: changeType,
    ));
  }
}
