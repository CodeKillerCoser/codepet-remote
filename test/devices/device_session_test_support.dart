part of 'device_session_test.dart';

PairedDevice _device(String id) => PairedDevice(deviceId: id, displayName: id, connectionKind: DeviceConnectionKind.demo);

ConversationSummary _conversation(
  String id,
  String? root,
  int milliseconds, {
  String providerId = 'test',
  String? title,
}) => ConversationSummary(
  id: id, providerId: providerId, title: title ?? id, status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.readOnly, workspaceRoot: root,
  createdAt: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
);

ConversationSummary _routedConversation({
  String? domainId,
  required String nativeId,
  required String providerPluginId,
  required String providerInstanceId,
  required String workspaceRoot,
  required int updatedAt,
  String? title,
  RoutedResourceId? project,
}) {
  final resource = RoutedResourceId(
    providerId: providerInstanceId,
    nativeResourceId: nativeId,
  );
  final id = resource.key;
  return ConversationSummary(
    id: domainId ?? id,
    providerId: providerInstanceId,
    title: title ?? nativeId,
    status: ConversationStatus.idle,
    permissionLevel: PermissionLevel.readOnly,
    workspaceRoot: workspaceRoot,
    project: project,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    resource: resource,
  );
}

TurnTask _turnFor(
  ConversationSummary conversation,
  TurnStatus status,
  int updatedAt,
) {
  final conversationResource = conversation.resource!;
  final turnResource = RoutedResourceId(
    providerId: conversationResource.providerId,
    nativeResourceId: 'turn-live',
  );
  return TurnTask(
    id: turnResource.key,
    providerId: conversation.providerId,
    conversationId: conversationRoutingKey(conversation),
    status: status,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    resource: turnResource,
    conversationResource: conversationResource,
  );
}

typedef _ListConversationsHandler = Future<ConversationPage> Function({
  required String route,
  required String? cursor,
  required int limit,
});

class _ConversationListRequest {
  const _ConversationListRequest({
    required this.route,
    required this.projectFilter,
    required this.cursor,
    required this.limit,
  });

  final String route;
  final ConversationProjectFilter projectFilter;
  final String? cursor;
  final int limit;
}

class _FakeClient implements GatewayClient, ProviderSnapshotGatewayClient {
  _FakeClient(
    this.values, {
    this.nextCursor,
    this.onListConversations,
    this.onDescribeProvider,
    this.providers = const [_listProvider],
  });
  final List<ConversationSummary> values;
  final String? nextCursor;
  final _ListConversationsHandler? onListConversations;
  final Future<GatewayProvider> Function(String providerId)?
      onDescribeProvider;
  final List<GatewayProvider> providers;
  final StreamController<List<GatewayProvider>> snapshots = StreamController.broadcast();
  @override Stream<List<GatewayProvider>> get providerSnapshots => snapshots.stream;
  final List<String> describeProviderIds = [];
  final List<_ConversationListRequest> listRequests = [];
  final StreamController<GatewayEvent> controller = StreamController<GatewayEvent>.broadcast();
  String _cursor = 'handshake';
  bool closed = false;
  @override Stream<GatewayEvent> get events => controller.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; controller.add(event); }
  @override Future<GatewayHandshake> connect() async => GatewayHandshake(protocolVersion: 1, providers: providers, eventCursor: 'handshake', deviceDescriptor: const DeviceDescriptor(deviceName: 'Test', operatingSystem: 'TestOS', systemVersion: '1'));
  @override Future<GatewayProvider> describeProvider(String providerId) {
    describeProviderIds.add(providerId);
    final handler = onDescribeProvider;
    return handler == null
        ? Future.value(
            providers.singleWhere((provider) => provider.id == providerId),
          )
        : handler(providerId);
  }
  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    listRequests.add(_ConversationListRequest(
      route: providerId,
      projectFilter: projectFilter,
      cursor: cursor,
      limit: limit,
    ));
    final handler = onListConversations;
    if (handler != null) {
      return handler(route: providerId, cursor: cursor, limit: limit);
    }
    return ConversationPage(
      conversations: values,
      nextCursor: nextCursor,
      snapshotCursor: _cursor,
    );
  }
  @override Future<ConversationPage> searchConversations({required String providerId, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: _cursor);
  @override Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) async => const ConversationInteraction(selection: TurnSendSelection());
  @override Future<ConversationSummary> createConversation({required String providerId, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw UnimplementedError();
  @override Future<TurnSendReceipt> sendTurn({required String providerId, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();
  @override Future<void> close() async { closed = true; await snapshots.close(); await controller.close(); }
}

class _ProjectFakeClient extends _FakeClient implements ProjectGatewayClient {
  _ProjectFakeClient({
    required List<GatewayProject> projects,
    required List<ConversationSummary> conversations,
    List<GatewayProvider> providers = const [_projectProvider],
    Future<GatewayProvider> Function(String providerId)? onDescribeProvider,
  })  : projects = List.of(projects),
        super(conversations, providers: providers, onDescribeProvider: onDescribeProvider);

  final List<GatewayProject> projects;
  int projectListCalls = 0;
  Completer<ProjectPage>? nextProjectPage;

  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    listRequests.add(_ConversationListRequest(
      route: providerId,
      projectFilter: projectFilter,
      cursor: cursor,
      limit: limit,
    ));
    final filtered = values.where((conversation) => switch (projectFilter) {
          AllConversationFilter() => true,
          StandaloneConversationFilter() => conversation.project == null,
          ProjectConversationFilter(:final project) =>
            conversation.project == project,
        });
    return ConversationPage(
      conversations: filtered.take(limit).toList(growable: false),
      snapshotCursor: latestEventCursor!,
    );
  }

  @override
  Future<ProjectPage> listProjects({
    required String providerId,
    String? cursor,
    int limit = 50,
  }) async {
    projectListCalls++;
    final pending = nextProjectPage;
    if (pending != null) {
      nextProjectPage = null;
      return pending.future;
    }
    return ProjectPage(
      projects: projects.take(limit).toList(growable: false),
      snapshotCursor: latestEventCursor!,
    );
  }

  @override
  Future<GatewayProject> getProject(RoutedResourceId project) async =>
      projects.firstWhere((candidate) => candidate.resource == project);

  @override
  Future<GatewayProject> createProject({
    required String providerId,
    required String idempotencyKey,
    required String name,
    required List<ProjectRoot> roots,
    Map<String, String> metadata = const {},
  }) async {
    final now = DateTime.now().toUtc();
    final project = GatewayProject(
      resource: RoutedResourceId(
        providerId: providerId,
        nativeResourceId: 'created-${projects.length}',
      ),
      name: name,
      roots: roots,
      metadata: metadata,
      position: projects.length,
      createdAt: now,
      updatedAt: now,
    );
    projects.add(project);
    return project;
  }

  @override
  Future<GatewayProject> updateProject({
    required RoutedResourceId project,
    String? name,
    List<ProjectRoot>? roots,
    Map<String, String>? metadata,
  }) async {
    final index = projects.indexWhere((item) => item.resource == project);
    final current = projects[index];
    final updated = GatewayProject(
      resource: project,
      name: name ?? current.name,
      roots: roots ?? current.roots,
      metadata: metadata ?? current.metadata,
      position: current.position,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt.add(const Duration(seconds: 1)),
    );
    projects[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteProject(RoutedResourceId project) async {
    projects.removeWhere((item) => item.resource == project);
  }
}

class _FailingClient implements GatewayClient {
  bool closeCalled = false;
  @override Stream<GatewayEvent> get events => const Stream.empty();
  @override String? get latestEventCursor => null;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(null, events);
  @override Future<GatewayHandshake> connect() => Future.error(
    const GatewayConnectionException(
      'first connection failed',
      retryable: true,
    ),
  );
  @override Future<GatewayProvider> describeProvider(String providerId) => throw StateError('not reached');
  @override Future<ConversationPage> listConversations({required String providerId, required ConversationProjectFilter projectFilter, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationPage> searchConversations({required String providerId, required String searchTerm, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<ConversationSummary> createConversation({required String providerId, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw StateError('not reached');
  @override Future<TurnSendReceipt> sendTurn({required String providerId, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw StateError('not reached');
  @override Future<void> close() async {
    closeCalled = true;
    throw StateError('close also failed');
  }
}

class _ControlledConnectClient extends _FailingClient {
  final Completer<void> connectStarted = Completer<void>();
  final Completer<GatewayHandshake> connectResult =
      Completer<GatewayHandshake>();

  @override
  Future<GatewayHandshake> connect() {
    if (!connectStarted.isCompleted) connectStarted.complete();
    return connectResult.future;
  }
}

const _primaryRoute = 'codex-work';

const _listProvider = GatewayProvider(
  id: _primaryRoute,
  displayName: 'Codex Work',
  status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.get'],
  ),
);

const _projectProvider = GatewayProvider(
  id: _primaryRoute,
  displayName: 'Codex Projects',
  status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'projects-1',
    methods: [
      'project.list',
      'project.get',
      'project.create',
      'project.update',
      'project.delete',
      'conversation.list',
      'conversation.create',
    ],
  ),
);

GatewayProject _gatewayProject() => GatewayProject(
      resource: const RoutedResourceId(
        providerId: _primaryRoute,
        nativeResourceId: 'project-1',
      ),
      name: 'Project One',
      roots: const [ProjectRoot(path: '/same/cwd')],
      metadata: const {},
      position: 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );

const _secondaryRoute = 'claude-work';

const _secondaryListProvider = GatewayProvider(
  id: _secondaryRoute,
  displayName: 'Claude Work',
  status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.get'],
  ),
);

class _NonRetryableClient extends _FailingClient {
  @override
  Future<GatewayHandshake> connect() => Future.error(
    const GatewayConnectionException('credential rejected'),
  );
}

class _DelayedCleanupFailingClient extends _FailingClient {
  final Completer<void> closeStarted = Completer<void>();
  final Completer<void> _finishClose = Completer<void>();

  void finishClose() {
    if (!_finishClose.isCompleted) _finishClose.complete();
  }

  @override
  Future<void> close() async {
    closeCalled = true;
    if (!closeStarted.isCompleted) closeStarted.complete();
    await _finishClose.future;
  }
}

class _ManagedClient extends _FakeClient implements ManagedConnectionGatewayClient {
  _ManagedClient() : super(const []);
  final availability = StreamController<bool>.broadcast();
  int hints = 0;
  bool? optimize;
  @override bool get managesConnection => true;
  @override Stream<bool> get connectionAvailability => availability.stream;
  @override void reconcileConnection({bool? optimize}) { hints++; this.optimize = optimize; }
  @override Future<void> close() async { await super.close(); await availability.close(); }
}
