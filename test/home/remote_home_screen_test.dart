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
            conversation < (project == 0 ? 9 : 1);
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
      findsNothing,
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
      find.byKey(const Key('recent-conversation-pages-test\u0000p0-8')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('show-more-recent-pages')));
    await tester.pump();
    expect(
      find.byKey(const Key('recent-conversation-pages-test\u0000p0-8')),
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
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) async => const ConversationPage(conversations: [], snapshotCursor: 'handshake');
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: 'handshake');
  @override Future<void> close() => controller.close();
}
