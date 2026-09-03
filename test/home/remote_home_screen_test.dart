import 'dart:async';

import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/features/home/remote_home_screen.dart';
import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/sync/gateway_event_window.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/gateway/demo_gateway_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('hides projects when project.list is absent even with cwd values',
      (tester) async {
    _useTallSurface(tester);
    final client = _PagedClient(
      ({required cursor, required limit}) async => ConversationPage(
        conversations: [
          _conversation(
            'cwd-only',
            '只有 cwd 的会话',
            workspaceRoot: '/looks/like/a/project',
          ),
        ],
        snapshotCursor: 'handshake',
      ),
    );
    final session = _sessionForClient('no-project-capability', client);
    final connect = session.connect();
    await tester.pump(const Duration(milliseconds: 500));
    await connect;
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    expect(
      find.byKey(const Key('projects-section-no-project-capability')),
      findsNothing,
    );
    expect(find.text('只有 cwd 的会话'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('shows project.list results and loads project conversations by id',
      (tester) async {
    _useTallSurface(tester);
    final session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'demo-studio',
        displayName: 'Demo',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: DemoGatewayClient.new,
    );
    final connect = session.connect();
    await tester.pump(const Duration(milliseconds: 500));
    await connect;
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    final project = session.selectedProviderProjects.single;
    expect(find.byKey(const Key('projects-section-demo-studio')), findsOneWidget);
    expect(find.byKey(Key('project-card-${project.key}')), findsOneWidget);
    expect(find.text('Gateway 协议契约核对'), findsOneWidget);
    expect(find.text('实现 Remote 会话流'), findsNothing);

    await tester.tap(find.byKey(Key('project-${project.key}')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump();

    expect(find.text('实现 Remote 会话流'), findsOneWidget);
    expect(
      session.conversationsForProject(project).single.workspaceRoot,
      '/projects/codepet-remote',
    );
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('exposes project create edit and delete controls independently',
      (tester) async {
    _useTallSurface(tester);
    final session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'demo-studio',
        displayName: 'Demo',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: DemoGatewayClient.new,
    );
    final connect = session.connect();
    await tester.pump(const Duration(milliseconds: 500));
    await connect;
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    expect(find.byKey(const Key('project-create')), findsOneWidget);
    final project = session.selectedProviderProjects.single;
    await tester.tap(find.byKey(Key('project-menu-${project.key}')));
    await tester.pumpAndSettle();
    expect(find.text('编辑项目'), findsOneWidget);
    expect(find.text('删除项目'), findsOneWidget);

    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('project-create')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('project-name')), '新项目');
    await tester.enterText(find.byKey(const Key('project-roots')), '/tmp/new');
    await tester.tap(find.byKey(const Key('confirm-project-save')));
    await tester.pumpAndSettle();

    expect(session.selectedProviderProjects.map((item) => item.name),
        contains('新项目'));
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('does not infer one project CRUD capability from another',
      (tester) async {
    _useTallSurface(tester);
    final session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'partial-projects',
        displayName: 'Partial',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: _EventClient.new,
    );
    session.connectionState = DeviceConnectionState.online;
    session.handshake = const GatewayHandshake(
      protocolVersion: 1,
      serverName: 'Test',
      serverVersion: '1',
      providers: [_updateOnlyProjectProvider],
      eventCursor: 'handshake',
    );
    session.projects = [_homeProject()];
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    expect(find.byKey(const Key('project-create')), findsNothing);
    final project = session.projects.single;
    await tester.tap(find.byKey(Key('project-menu-${project.key}')));
    await tester.pumpAndSettle();
    expect(find.text('编辑项目'), findsOneWidget);
    expect(find.text('删除项目'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('new conversation exposes provider-declared create options',
      (tester) async {
    _useTallSurface(tester);
    final client = _PagedClient(
      ({required cursor, required limit}) async => const ConversationPage(
        conversations: [],
        snapshotCursor: 'handshake',
      ),
    );
    final session = _sessionForClient('create-options', client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    await tester.tap(find.byKey(const Key('home-new')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('new-conversation-title')), findsNothing);
    expect(
      find.byKey(const Key('new-conversation-workspace-mode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('new-conversation-access-mode')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('new-conversation-reasoning-effort')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('new-conversation-model')), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('shows Provider identity from the Host handshake', (tester) async {
    _useTallSurface(tester);
    final client = _PagedClient(
      ({required cursor, required limit}) async =>
          const ConversationPage(
            conversations: [],
            snapshotCursor: 'handshake',
          ),
    );
    final session = _sessionForClient('provider-identity', client);
    await session.connect();

    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    expect(find.byKey(const Key('connected-providers')), findsOneWidget);
    expect(find.text('Codex Work'), findsOneWidget);
    expect(find.byIcon(Icons.terminal), findsOneWidget);
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('device-selector')))
          .scrollDirection,
      Axis.horizontal,
    );
    expect(
      tester
          .widget<ListView>(find.byKey(const Key('connected-providers')))
          .scrollDirection,
      Axis.horizontal,
    );
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('failed state leaves loading and allows a manual reconnect', (tester) async {
    _useTallSurface(tester);
    var clientBuilds = 0;
    final session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'bounded-retry',
        displayName: 'Bounded retry',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: () {
        clientBuilds++;
        return _EventClient();
      },
      autoReconnect: false,
    );
    session.connectionState = DeviceConnectionState.failed;
    session.error = 'all Gateway candidates timed out';

    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    expect(clientBuilds, 0);
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('设备连接失败'), findsOneWidget);
    final reconnect = find.widgetWithText(TextButton, '重新连接').first;
    expect(tester.widget<TextButton>(reconnect).onPressed, isNotNull);

    await tester.tap(reconnect);
    await tester.pump();
    await tester.pump();

    expect(clientBuilds, 1);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(find.text('设备连接失败'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('recent pagination loads and deduplicates the shared projection', (tester) async {
    _useTallSurface(tester);
    final initial = [
      for (var index = 0; index < 8; index++)
        _conversation(
          'shared-$index',
          '共享会话 $index',
          workspaceRoot: '/shared',
          updatedMilliseconds: 2000 - index,
        ),
    ];
    final client = _PagedClient(
      ({required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: initial,
            nextCursor: 'recent-2',
            snapshotCursor: 'handshake',
          );
        }
        return ConversationPage(
          conversations: [
            _conversation(
              'shared-0',
              '不应覆盖的新标题',
              workspaceRoot: '/shared',
              updatedMilliseconds: 100,
            ),
            _conversation(
              'shared-8',
              '共享会话 8',
              workspaceRoot: '/shared',
              updatedMilliseconds: 1900,
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = _sessionForClient('network-recent', client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    await tester.tap(
      find.byKey(const Key('show-more-recent-network-recent')),
    );
    await tester.pumpAndSettle();

    expect(client.cursors, [null, 'recent-2']);
    expect(session.conversations, hasLength(9));
    expect(
      session.conversations.where((item) => item.id == 'shared-0'),
      hasLength(1),
    );
    expect(session.conversations.first.title, '共享会话 0');
    expect(
      find.byKey(const Key(
        'recent-conversation-network-recent-test\u0000shared-8',
      )),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('load more disables duplicates and exposes retryable errors', (tester) async {
    _useTallSurface(tester);
    final failedPage = Completer<ConversationPage>();
    var attempts = 0;
    final client = _PagedClient(
      ({required String? cursor, required int limit}) {
        if (cursor == null) {
          return Future.value(ConversationPage(
            conversations: [
              for (var index = 0; index < 8; index++)
                _conversation(
                  'retry-$index',
                  '重试会话 $index',
                  workspaceRoot: '/retry',
                  updatedMilliseconds: 3000 - index,
                ),
            ],
            nextCursor: 'retry-2',
            snapshotCursor: 'handshake',
          ));
        }
        attempts++;
        if (attempts == 1) return failedPage.future;
        return Future.value(ConversationPage(
          conversations: [
            _conversation(
              'retry-8',
              '重试成功会话',
              workspaceRoot: '/retry',
              updatedMilliseconds: 1900,
            ),
          ],
          snapshotCursor: 'handshake',
        ));
      },
    );
    final session = _sessionForClient('loading-retry', client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );
    final showMore = find.byKey(
      const Key('show-more-recent-loading-retry'),
    );

    await tester.tap(showMore);
    await tester.pump();

    expect(client.cursors, [null, 'retry-2']);
    expect(tester.widget<TextButton>(showMore).onPressed, isNull);
    await tester.tap(showMore);
    await tester.pump();
    expect(client.cursors, [null, 'retry-2']);

    failedPage.completeError(StateError('network page failed'));
    await tester.pumpAndSettle();

    expect(find.textContaining('network page failed'), findsWidgets);
    expect(tester.widget<TextButton>(showMore).onPressed, isNotNull);

    await tester.tap(showMore);
    await tester.pumpAndSettle();

    expect(client.cursors, [null, 'retry-2', 'retry-2']);
    expect(find.textContaining('network page failed'), findsNothing);
    expect(
      find.byKey(const Key(
        'recent-conversation-loading-retry-test\u0000retry-8',
      )),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('listens to events from a device added to the same list instance', (tester) async {
    final client = _EventClient();
    await tester.pumpWidget(MaterialApp(home: _MutableSessionsHarness(client: client)));

    await tester.tap(find.byKey(const Key('add-dynamic-session')));
    await tester.pumpAndSettle();
    expect(find.text('动态事件会话'), findsNothing);
    expect(find.text('Host Metadata'), findsOneWidget);
    expect(find.text('TestOS 9'), findsOneWidget);

    client.emit(ConversationUpsertedEvent(
      eventCursor: 'event-1',
      conversation: _conversation(
        'dynamic',
        '动态事件会话',
        updatedMilliseconds: 3000,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('动态事件会话'), findsOneWidget);

    client.emit(ConversationUpsertedEvent(
      eventCursor: 'event-2',
      conversation: _conversation(
        'dynamic',
        '刷新后的标题',
        updatedMilliseconds: 2000,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('动态事件会话'), findsNothing);
    expect(find.text('刷新后的标题'), findsOneWidget);
  });
}

void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 4000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

DeviceSession _sessionForClient(String deviceId, GatewayClient client) =>
    DeviceSession(
      device: PairedDevice(
        deviceId: deviceId,
        displayName: deviceId,
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: () => client,
    );

class _HomeHarness extends StatefulWidget {
  const _HomeHarness({required this.sessions});

  final List<DeviceSession> sessions;

  @override
  State<_HomeHarness> createState() => _HomeHarnessState();
}

class _HomeHarnessState extends State<_HomeHarness> {
  int selectedIndex = 0;

  @override
  Widget build(BuildContext context) => RemoteHomeScreen(
        sessions: widget.sessions,
        selectedIndex: selectedIndex,
        onSelectDevice: (index) => setState(() {
          selectedIndex = index;
        }),
        onAddDevice: () {},
        onOpenSettings: () {},
      );
}

class _MutableSessionsHarness extends StatefulWidget {
  const _MutableSessionsHarness({required this.client});
  final _EventClient client;
  @override State<_MutableSessionsHarness> createState() => _MutableSessionsHarnessState();
}

class _MutableSessionsHarnessState extends State<_MutableSessionsHarness> {
  final List<DeviceSession> sessions = [];
  int selectedIndex = 0;

  void addSession() {
    final session = DeviceSession(
      device: const PairedDevice(deviceId: 'dynamic', displayName: '动态设备', connectionKind: DeviceConnectionKind.demo),
      clientFactory: () => widget.client,
    );
    setState(() {
      sessions.add(session);
      selectedIndex = sessions.length - 1;
    });
    unawaited(session.connect());
  }

  @override
  void dispose() {
    for (final session in sessions) {
      session.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
    RemoteHomeScreen(
      sessions: sessions,
      selectedIndex: selectedIndex,
      onSelectDevice: (index) => setState(() => selectedIndex = index),
      onAddDevice: () {},
      onOpenSettings: () {},
    ),
    Positioned(
      left: 8,
      bottom: 8,
      child: ElevatedButton(key: const Key('add-dynamic-session'), onPressed: addSession, child: const Text('add')),
    ),
  ]);
}

ConversationSummary _conversation(
  String id,
  String title, {
  String workspaceRoot = '/dynamic',
  int updatedMilliseconds = 2000,
}) => ConversationSummary(
  id: id,
  providerId: 'test',
  title: title,
  status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.readOnly,
  workspaceRoot: workspaceRoot,
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(
    updatedMilliseconds,
    isUtc: true,
  ),
);

class _EventClient implements GatewayClient {
  final StreamController<GatewayEvent> controller = StreamController<GatewayEvent>.broadcast();
  void emit(GatewayEvent event) => controller.add(event);
  @override Stream<GatewayEvent> get events => controller.stream;
  @override String? get latestEventCursor => 'handshake';
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream('handshake', events);
  @override Future<GatewayHandshake> connect() async => const GatewayHandshake(protocolVersion: 1, serverName: 'Test', serverVersion: '1', providers: [], eventCursor: 'handshake', deviceDescriptor: DeviceDescriptor(deviceName: 'Host Metadata', operatingSystem: 'TestOS', systemVersion: '9'));
  @override Future<ConversationPage> listConversations({required GatewayProviderRoute route, required ConversationProjectFilter projectFilter, String? cursor, int limit = 50}) async => const ConversationPage(conversations: [], snapshotCursor: 'handshake');
  @override Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: 'handshake');
  @override Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) async => const ConversationInteraction(selection: TurnSendSelection());
  @override Future<ConversationSummary> createConversation({required GatewayProviderRoute route, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw UnimplementedError();
  @override Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();
  @override Future<void> close() => controller.close();
}

typedef _PageHandler = Future<ConversationPage> Function({
  required String? cursor,
  required int limit,
});

class _PagedClient implements GatewayClient {
  _PagedClient(this.pageHandler);

  final _PageHandler pageHandler;
  final List<String?> cursors = [];
  final StreamController<GatewayEvent> controller =
      StreamController<GatewayEvent>.broadcast();

  @override
  Stream<GatewayEvent> get events => controller.stream;

  @override
  String? get latestEventCursor => 'handshake';

  @override
  GatewayEventWindow openEventWindow() =>
      GatewayEventWindow.forStream('handshake', events);

  @override
  Future<GatewayHandshake> connect() async => const GatewayHandshake(
        protocolVersion: 1,
        serverName: 'Test',
        serverVersion: '1',
        providers: [_homeListProvider],
        eventCursor: 'handshake',
      );

  @override
  Future<ConversationPage> listConversations({
    required GatewayProviderRoute route,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) {
    cursors.add(cursor);
    return pageHandler(cursor: cursor, limit: limit);
  }

  @override
  Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();

  @override
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) async => ConversationSnapshot(
        detail: ConversationDetail(summary: conversation),
        snapshotCursor: 'handshake',
      );

  @override
  Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) async =>
      const ConversationInteraction(selection: TurnSendSelection());

  @override
  Future<ConversationSummary> createConversation({required GatewayProviderRoute route, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw UnimplementedError();

  @override
  Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();

  @override
  Future<void> close() => controller.close();
}

const _homeRoute = GatewayProviderRoute(
  deviceId: 'home-host',
  providerPluginId: 'dev.codepet.codex',
  providerInstanceId: 'test',
);

const _homeListProvider = GatewayProvider(
  route: _homeRoute,
  providerType: 'dev.codepet.codex',
  displayName: 'Codex Work',
  icon: 'codex',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'codex', displayName: 'Codex'),
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: [
      'conversation.list',
      'conversation.get',
      'conversation.create',
    ],
    conversationCreate: ConversationCreateCapabilities(
      supportsTitle: false,
      selection: TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [
            ProviderChoice(id: 'workspace-write', displayName: 'Workspace write'),
          ],
          defaultId: 'workspace-write',
        ),
        reasoningEffort: ProviderChoiceSet(
          options: [ProviderChoice(id: 'high', displayName: 'High')],
          defaultId: 'high',
        ),
        modelCatalog: FlatModelCatalog(
          models: [ProviderChoice(id: 'gpt-test', displayName: 'GPT Test')],
          defaultSelection: FlatModelSelection(modelId: 'gpt-test'),
        ),
      ),
      workspaceMode: ProviderChoiceSet(
        options: [
          ProviderChoice(id: 'main', displayName: 'Main workspace'),
          ProviderChoice(id: 'worktree', displayName: 'Worktree'),
        ],
        defaultId: 'main',
      ),
    ),
  ),
);

const _updateOnlyProjectProvider = GatewayProvider(
  route: _homeRoute,
  providerType: 'dev.codepet.codex',
  displayName: 'Codex Projects',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'codex', displayName: 'Codex'),
  capabilities: GatewayCapabilities(
    revision: 'partial-projects-1',
    methods: ['project.list', 'project.update', 'conversation.list'],
  ),
);

GatewayProject _homeProject() => GatewayProject(
      resource: const RoutedResourceId(
        route: _homeRoute,
        nativeResourceId: 'project-1',
      ),
      name: 'Partial project',
      roots: const [ProjectRoot(path: '/partial')],
      metadata: const {},
      position: 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );
