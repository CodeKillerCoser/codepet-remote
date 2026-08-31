import 'dart:async';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_session.dart';
import 'package:codepet_remote/features/home/remote_home_screen.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('collapses and expands project and recent sections', (tester) async {
    _useTallSurface(tester);
    final session = _loadedSession(
      'sections',
      [_conversation('section-conversation', '分区会话')],
    );
    await tester.pumpWidget(MaterialApp(home: _HomeHarness(sessions: [session])));

    final projectKey = 'sections\u0000/dynamic';
    expect(find.byKey(Key('project-card-$projectKey')), findsOneWidget);
    expect(
      find.byKey(const Key(
        'recent-conversation-sections-test\u0000section-conversation',
      )),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('projects-section-sections')));
    await tester.pump();
    expect(find.byKey(Key('project-card-$projectKey')), findsNothing);

    await tester.tap(find.byKey(const Key('projects-section-sections')));
    await tester.pump();
    expect(find.byKey(Key('project-card-$projectKey')), findsOneWidget);

    await tester.tap(find.byKey(const Key('recent-section-sections')));
    await tester.pump();
    expect(
      find.byKey(const Key(
        'recent-conversation-sections-test\u0000section-conversation',
      )),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('pages projects, project conversations and recent conversations', (tester) async {
    _useTallSurface(tester);
    final conversations = <ConversationSummary>[
      for (var project = 0; project < 7; project++)
        for (var conversation = 0;
            conversation < (project == 0 ? 21 : 1);
            conversation++)
          _conversation(
            'p$project-$conversation',
            '项目 $project 会话 $conversation',
            workspaceRoot: '/project-$project',
            updatedMilliseconds: project == 0
                ? 100000 - conversation
                : 50000 - project,
          ),
    ];
    final session = _loadedSession('pages', conversations);
    await tester.pumpWidget(MaterialApp(home: _HomeHarness(sessions: [session])));

    expect(
      find.byKey(const Key('project-card-pages\u0000/project-6')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('show-more-projects-pages')));
    await tester.pump();
    expect(
      find.byKey(const Key('project-card-pages\u0000/project-6')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('show-more-projects-pages')), findsNothing);

    const firstProjectKey = 'pages\u0000/project-0';
    await tester.tap(find.byKey(const Key('project-$firstProjectKey')));
    await tester.pump();
    expect(
      find.byKey(const Key(
        'project-conversation-pages\u0000/project-0-test\u0000p0-8',
      )),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key(
      'show-more-project-conversations-$firstProjectKey',
    )));
    await tester.pump();
    expect(
      find.byKey(const Key(
        'project-conversation-pages\u0000/project-0-test\u0000p0-8',
      )),
      findsOneWidget,
    );
    expect(
      find.byKey(Key('show-more-project-conversations-$firstProjectKey')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('open-project-$firstProjectKey')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-screen-conversation-test\u0000p0-8')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('show-more-project-screen-conversations')),
    );
    await tester.pump();
    expect(
      find.byKey(const Key('project-screen-conversation-test\u0000p0-8')),
      findsOneWidget,
    );
    Navigator.of(
      tester.element(find.byKey(const Key('project-conversation-list'))),
    ).pop();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('recent-conversation-pages-test\u0000p0-20')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('show-more-recent-pages')));
    await tester.pump();
    expect(
      find.byKey(const Key('recent-conversation-pages-test\u0000p0-20')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('project pagination loads a Host page and refreshes recent data', (tester) async {
    _useTallSurface(tester);
    final client = _PagedClient(
      ({required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [
              for (var index = 0; index < 6; index++)
                _conversation(
                  'project-$index',
                  '项目 $index',
                  workspaceRoot: '/project-$index',
                  updatedMilliseconds: 1000 - index,
                ),
            ],
            nextCursor: 'projects-2',
            snapshotCursor: 'handshake',
          );
        }
        expect(cursor, 'projects-2');
        return ConversationPage(
          conversations: [
            _conversation(
              'project-6',
              '项目 6',
              workspaceRoot: '/project-6',
              updatedMilliseconds: 900,
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = _sessionForClient('network-projects', client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );

    expect(client.cursors, [null]);
    expect(
      find.byKey(const Key(
        'project-card-network-projects\u0000/project-6',
      )),
      findsNothing,
    );
    expect(
      find.byKey(const Key(
        'recent-conversation-network-projects-test\u0000project-6',
      )),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const Key('show-more-projects-network-projects')),
    );
    await tester.pumpAndSettle();

    expect(client.cursors, [null, 'projects-2']);
    expect(
      find.byKey(const Key(
        'project-card-network-projects\u0000/project-6',
      )),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key(
        'recent-conversation-network-projects-test\u0000project-6',
      )),
      findsOneWidget,
    );

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
    expect(find.text('9 个会话 · /shared'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('project conversation pagination crosses empty Host pages', (tester) async {
    _useTallSurface(tester);
    final client = _PagedClient(
      ({required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [
              for (var index = 0; index < 8; index++)
                _conversation(
                  'target-$index',
                  '目标会话 $index',
                  workspaceRoot: '/target',
                  updatedMilliseconds: 3000 - index,
                ),
            ],
            nextCursor: 'target-2',
            snapshotCursor: 'handshake',
          );
        }
        if (cursor == 'target-2') {
          return ConversationPage(
            conversations: [
              _conversation(
                'other-only',
                '其他项目会话',
                workspaceRoot: '/other',
                updatedMilliseconds: 2000,
              ),
            ],
            nextCursor: 'target-3',
            snapshotCursor: 'handshake',
          );
        }
        expect(cursor, 'target-3');
        return ConversationPage(
          conversations: [
            _conversation(
              'target-8',
              '目标会话 8',
              workspaceRoot: '/target',
              updatedMilliseconds: 1900,
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = _sessionForClient('empty-project-page', client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );
    const projectKey = 'empty-project-page\u0000/target';
    final showMore = find.byKey(
      const Key('show-more-project-conversations-$projectKey'),
    );

    await tester.tap(find.byKey(const Key('project-$projectKey')));
    await tester.pump();
    await tester.tap(showMore);
    await tester.pumpAndSettle();

    expect(client.cursors, [null, 'target-2']);
    expect(showMore, findsOneWidget);
    expect(
      find.byKey(const Key(
        'project-conversation-$projectKey-test\u0000target-8',
      )),
      findsNothing,
    );

    await tester.tap(showMore);
    await tester.pumpAndSettle();

    expect(client.cursors, [null, 'target-2', 'target-3']);
    expect(
      find.byKey(const Key(
        'project-conversation-$projectKey-test\u0000target-8',
      )),
      findsOneWidget,
    );
    expect(showMore, findsNothing);

    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('project screen pagination uses the shared Host cursor', (tester) async {
    _useTallSurface(tester);
    final client = _PagedClient(
      ({required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [
              for (var index = 0; index < 8; index++)
                _conversation(
                  'screen-$index',
                  '项目页会话 $index',
                  workspaceRoot: '/screen',
                  updatedMilliseconds: 3000 - index,
                ),
            ],
            nextCursor: 'screen-2',
            snapshotCursor: 'handshake',
          );
        }
        return ConversationPage(
          conversations: [
            _conversation(
              'screen-8',
              '项目页会话 8',
              workspaceRoot: '/screen',
              updatedMilliseconds: 1900,
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = _sessionForClient('project-screen-network', client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: _HomeHarness(sessions: [session])),
    );
    const projectKey = 'project-screen-network\u0000/screen';

    await tester.tap(find.byKey(const Key('open-project-$projectKey')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('project-screen-conversation-test\u0000screen-8')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const Key('show-more-project-screen-conversations')),
    );
    await tester.pumpAndSettle();

    expect(client.cursors, [null, 'screen-2']);
    expect(
      find.byKey(const Key('project-screen-conversation-test\u0000screen-8')),
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

  testWidgets('keeps collapse and pagination state isolated by device id', (tester) async {
    _useTallSurface(tester);
    final first = _loadedSession('first', _projectConversations('first'));
    final second = _loadedSession('second', _projectConversations('second'));
    await tester.pumpWidget(MaterialApp(
      home: _HomeHarness(sessions: [first, second]),
    ));

    await tester.tap(find.byKey(const Key('show-more-projects-first')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('recent-section-first')));
    await tester.pump();
    expect(
      find.byKey(const Key('project-card-first\u0000/first-project-6')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('device-second')));
    await tester.pump();
    expect(
      find.byKey(const Key('project-card-second\u0000/second-project-6')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('recent-conversation-second-test\u0000second-0')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('device-first')));
    await tester.pump();
    expect(
      find.byKey(const Key('project-card-first\u0000/first-project-6')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('recent-conversation-first-test\u0000first-0')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox());
    first.dispose();
    second.dispose();
  });

  testWidgets('sorts projects and conversations by updated time', (tester) async {
    _useTallSurface(tester);
    final session = _loadedSession('sorting', [
      _conversation(
        'old-project',
        '旧项目会话',
        workspaceRoot: '/old',
        updatedMilliseconds: 10,
      ),
      _conversation(
        'older-in-new',
        '新项目较早会话',
        workspaceRoot: '/new',
        updatedMilliseconds: 20,
      ),
      _conversation(
        'newest-in-new',
        '新项目最新会话',
        workspaceRoot: '/new',
        updatedMilliseconds: 30,
      ),
    ]);
    await tester.pumpWidget(MaterialApp(home: _HomeHarness(sessions: [session])));

    expect(
      tester.getTopLeft(
        find.byKey(const Key('project-card-sorting\u0000/new')),
      ).dy,
      lessThan(tester.getTopLeft(
        find.byKey(const Key('project-card-sorting\u0000/old')),
      ).dy),
    );

    await tester.tap(
      find.byKey(const Key('project-sorting\u0000/new')),
    );
    await tester.pump();
    expect(
      tester.getTopLeft(find.byKey(const Key(
        'project-conversation-sorting\u0000/new-test\u0000newest-in-new',
      ))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key(
        'project-conversation-sorting\u0000/new-test\u0000older-in-new',
      ))).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key(
        'recent-conversation-sorting-test\u0000newest-in-new',
      ))).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key(
        'recent-conversation-sorting-test\u0000older-in-new',
      ))).dy),
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
    expect(find.text('TestOS 9 · 在线'), findsOneWidget);

    client.emit(ConversationUpsertedEvent(
      eventCursor: 'event-1',
      conversation: _conversation('dynamic', '动态事件会话'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('动态事件会话'), findsOneWidget);
  });
}

void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 4000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

DeviceSession _loadedSession(
  String deviceId,
  List<ConversationSummary> conversations,
) {
  final session = DeviceSession(
    device: PairedDevice(
      deviceId: deviceId,
      displayName: deviceId,
      connectionKind: DeviceConnectionKind.demo,
    ),
    clientFactory: _EventClient.new,
  );
  session.connectionState = DeviceConnectionState.online;
  session.conversations = conversations;
  return session;
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

List<ConversationSummary> _projectConversations(String prefix) => [
  for (var index = 0; index < 7; index++)
    _conversation(
      '$prefix-$index',
      '$prefix 会话 $index',
      workspaceRoot: '/$prefix-project-$index',
      updatedMilliseconds: 100 - index,
    ),
];

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
  @override Future<ConversationPage> listConversations({required GatewayProviderRoute route, String? cursor, int limit = 50}) async => const ConversationPage(conversations: [], snapshotCursor: 'handshake');
  @override Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: 'handshake');
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
  Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();

  @override
  Future<void> close() => controller.close();
}

const _homeRoute = GatewayProviderRoute(
  deviceId: 'home-host',
  providerPluginId: 'dev.codepet.codex',
  providerInstanceId: 'codex-work',
);

const _homeListProvider = GatewayProvider(
  route: _homeRoute,
  providerType: 'dev.codepet.codex',
  displayName: 'Codex Work',
  status: ProviderStatus.ready,
  methods: ['conversation.list', 'conversation.get'],
);
