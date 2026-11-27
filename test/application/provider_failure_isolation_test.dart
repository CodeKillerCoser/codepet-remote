import 'dart:async';

import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/features/home/remote_home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recent_gateway.dart';

GatewayProvider agent(String id, {bool described = true, int generation = 1}) =>
    GatewayProvider(
      id: id,
      displayName: id,
      status: ProviderStatus.ready,
      generation: generation,
      capabilitiesLoaded: described,
      capabilities: GatewayCapabilities(
        revision: 'v$generation',
        methods: described
            ? ['project.list', 'conversation.list', 'turn.send']
            : [],
      ),
    );

GatewayProject project(String id, String name) => GatewayProject(
  resource: RoutedResourceId(providerId: id, nativeResourceId: name),
  name: name,
  roots: const [ProjectRoot(path: '/workspace')],
  metadata: const {},
  position: 0,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

ConversationSummary chat(String id, String title) => ConversationSummary(
  id: 'chat-$id',
  providerId: id,
  title: title,
  status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.readOnly,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
  resource: RoutedResourceId(providerId: id, nativeResourceId: 'chat-$id'),
);

class IsolationGateway extends RecentGatewayFake
    implements ProviderSnapshotGatewayClient {
  List<GatewayProvider> providers = [agent('a'), agent('b')];
  final snapshots = StreamController<List<GatewayProvider>>.broadcast(
    sync: true,
  );
  final calls = <(String, String, String?)>[];
  Future<GatewayProvider> Function(String)? describe;
  Future<ProjectPage> Function(String, String?)? projects;
  Future<ConversationPage> Function(String, String?)? chats;
  bool badProject = false;
  bool closed = false;
  int connects = 0;
  @override
  Stream<List<GatewayProvider>> get providerSnapshots => snapshots.stream;
  @override
  Future<GatewayHandshake> connect() async {
    connects++;
    return GatewayHandshake(
      protocolVersion: 1,
      providers: providers,
      eventCursor: cursor,
      deviceDescriptor: const DeviceDescriptor(
        deviceName: 'Device',
        operatingSystem: 'Test',
        systemVersion: '1',
      ),
    );
  }

  @override
  Future<GatewayProvider> describeProvider(String id) async =>
      describe == null ? agent(id) : await describe!(id);
  @override
  Future<ProjectPage> listProjects({
    required String providerId,
    String? cursor,
    int limit = 50,
  }) async {
    calls.add(('projects', providerId, cursor));
    if (providerId == 'a' && badProject) {
      throw const GatewayProtocolException(
        code: 'provider_response_invalid',
        message: 'Provider returned a project with invalid fields',
        retryable: false,
      );
    }
    return projects == null
        ? page(providerId, providerId)
        : await projects!(providerId, cursor);
  }

  ProjectPage page(String id, String name) => ProjectPage(
    projects: [project(id, name)],
    snapshotCursor: cursor,
    nextCursor: 'next',
  );
  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    calls.add(('chat', providerId, cursor));
    return chats == null
        ? chatPage(providerId)
        : await chats!(providerId, cursor);
  }

  ConversationPage chatPage(String id) => ConversationPage(
    conversations: [chat(id, id)],
    snapshotCursor: cursor,
    nextCursor: 'next',
  );
  @override
  Future<TurnSendReceipt> sendTurn({
    required String providerId,
    required ConversationSummary conversation,
    required String clientRequestId,
    required String capabilityRevision,
    required String text,
    required TurnSendSelection selection,
  }) async {
    if (providerId == 'a') throw StateError('Provider a execution failed');
    return TurnSendReceipt(
      clientRequestId: clientRequestId,
      turn: TurnTask(
        id: 'healthy-turn',
        providerId: providerId,
        conversationId: conversation.id,
        status: TurnStatus.completed,
        updatedAt: DateTime.utc(2026),
      ),
      inputItem: null,
      effectiveSelection: selection,
    );
  }

  void emit(GatewayEvent event) {
    cursor = event.eventCursor;
    stream.add(event);
  }

  @override
  Future<void> close() async {
    closed = true;
    await snapshots.close();
    await super.close();
  }
}

DeviceSession sessionFor(
  IsolationGateway client, {
  Duration timeout = const Duration(seconds: 10),
}) => DeviceSession(
  device: const PairedDevice(
    deviceId: 'isolated',
    displayName: 'Device',
    connectionKind: DeviceConnectionKind.demo,
  ),
  clientFactory: () => client,
  autoReconnect: false,
  providerLoadTimeout: timeout,
);

void main() {
  test(
    'execution failure is scoped to its request, healthy sends still work',
    () async {
      final client = IsolationGateway();
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect();
      await pumpEventQueue();
      final lease = session.runtimeLease!;
      await expectLater(
        lease.sendTurn(
          providerId: 'a',
          conversation: chat('a', 'a'),
          clientRequestId: 'a-message',
          capabilityRevision: 'v1',
          text: 'a',
          selection: const TurnSendSelection(),
        ),
        throwsStateError,
      );
      final good = await lease.sendTurn(
        providerId: 'b',
        conversation: chat('b', 'b'),
        clientRequestId: 'b-message',
        capabilityRevision: 'v1',
        text: 'b',
        selection: const TurnSendSelection(),
      );
      expect(good.turn.status, TurnStatus.completed);
      expect(session.ownsRuntimeLease(lease), isTrue);
      expect(client.closed, isFalse);
    },
  );
  test(
    'online and healthy Provider do not wait for a sibling description',
    () async {
      final client = IsolationGateway()
        ..providers = [
          agent('a', described: false),
          agent('b', described: false),
        ];
      final pending = Completer<GatewayProvider>();
      client.describe = (id) =>
          id == 'a' ? pending.future : Future.value(agent('b'));
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect().timeout(const Duration(seconds: 1));
      expect(session.connectionState, DeviceConnectionState.online);
      await pumpEventQueue();
      expect(
        session.providerData('a', ProviderDataKind.capabilities).status,
        ProviderDataStatus.loading,
      );
      expect(session.handshake!.providers.last.capabilitiesLoaded, isTrue);
      session.selectProvider(session.handshake!.providers.last);
      await pumpEventQueue();
      expect(session.selectedProviderProjects.single.name, 'b');
      pending.completeError(StateError('a crashed'));
      await pumpEventQueue();
      expect(
        session.providerData('a', ProviderDataKind.capabilities).status,
        ProviderDataStatus.failed,
      );
      expect(session.connectionState, DeviceConnectionState.online);
      expect(client.closed, isFalse);
    },
  );

  test('invalid project is local, conversations load and retry reuses the connection', () async {
    final client = IsolationGateway()..badProject = true;
    final session = sessionFor(client);
    addTearDown(session.dispose);
    await session.connect();
    await pumpEventQueue();
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.selectedProviderConversations.single.title, 'a');
    expect(
      session.providerData('a', ProviderDataKind.projects).error,
      contains('invalid fields'),
    );
    session.selectProvider(agent('b'));
    await pumpEventQueue();
    expect(session.selectedProviderProjects.single.name, 'b');
    expect(session.providerData('b', ProviderDataKind.projects).error, isNull);
    session.selectProvider(agent('a'));
    client.badProject = false;
    await session.retryProviderData('a', ProviderDataKind.projects);
    expect(session.selectedProviderProjects.single.name, 'a');
    expect(
      session.providerData('a', ProviderDataKind.projects).status,
      ProviderDataStatus.ready,
    );
    expect(client.connects, 1);
  });

  test(
    'hung project times out locally while a different Provider loads',
    () async {
      final client = IsolationGateway();
      final pending = Completer<ProjectPage>();
      client.projects = (id, _) =>
          id == 'a' ? pending.future : Future.value(client.page(id, id));
      final session = sessionFor(
        client,
        timeout: const Duration(milliseconds: 30),
      );
      addTearDown(session.dispose);
      await session.connect();
      session.selectProvider(agent('b'));
      await pumpEventQueue();
      expect(session.selectedProviderProjects.single.name, 'b');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        session.providerData('a', ProviderDataKind.projects).status,
        ProviderDataStatus.failed,
      );
      pending.complete(client.page('a', 'late'));
      await pumpEventQueue();
      expect(session.projects.any((p) => p.name == 'late'), isFalse);
      expect(session.connectionState, DeviceConnectionState.online);
    },
  );

  test('paging a different Provider is not gated by the old tab', () async {
    final client = IsolationGateway();
    final slowProjects = Completer<ProjectPage>();
    final slowChats = Completer<ConversationPage>();
    client.projects = (id, cursor) => id == 'a' && cursor != null
        ? slowProjects.future
        : Future.value(client.page(id, id));
    client.chats = (id, cursor) => id == 'a' && cursor != null
        ? slowChats.future
        : Future.value(client.chatPage(id));
    final session = sessionFor(client);
    addTearDown(session.dispose);
    await session.connect();
    await pumpEventQueue();
    final aProjects = session.loadMoreSelectedProviderProjects();
    final aChats = session.loadMoreSelectedProviderConversations();
    session.selectProvider(agent('b'));
    await pumpEventQueue();
    expect(session.isLoadingMoreProjects, isFalse);
    expect(session.isLoadingMoreConversations, isFalse);
    await session.loadMoreSelectedProviderProjects();
    await session.loadMoreSelectedProviderConversations();
    expect(
      client.calls,
      containsAll([('projects', 'b', 'next'), ('chat', 'b', 'next')]),
    );
    slowProjects.completeError(StateError('old tab failed'));
    slowChats.completeError(StateError('old tab failed'));
    await Future.wait([aProjects, aChats]);
    expect(session.loadMoreProjectsError, isNull);
    expect(session.loadMoreError, isNull);
    expect(session.connectionState, DeviceConnectionState.online);
  });

  test(
    'old generation completion cannot replace new projects or loading gates',
    () async {
      final client = IsolationGateway();
      final old = Completer<ProjectPage>();
      var first = true;
      client.projects = (id, _) {
        if (id == 'a' && first) {
          first = false;
          return old.future;
        }
        return Future.value(client.page(id, 'fresh'));
      };
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect();
      await pumpEventQueue();
      client.snapshots.add([agent('a', generation: 2), agent('b')]);
      await pumpEventQueue();
      expect(session.selectedProviderProjects.single.name, 'fresh');
      old.complete(client.page('a', 'obsolete'));
      await pumpEventQueue();
      expect(session.selectedProviderProjects.single.name, 'fresh');
      expect(
        session.providerData('a', ProviderDataKind.projects).status,
        ProviderDataStatus.ready,
      );
    },
  );

  test(
    'snapshot loading replays a newer event without losing the connection',
    () async {
      final client = IsolationGateway();
      final pending = Completer<ConversationPage>();
      client.chats = (_, _) => pending.future;
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect();
      client.emit(
        ConversationUpsertedEvent(
          eventCursor: 'e1',
          conversation: chat('a', 'new event'),
        ),
      );
      pending.complete(
        ConversationPage(
          conversations: [chat('a', 'old snapshot')],
          snapshotCursor: 'e0',
        ),
      );
      await pumpEventQueue();
      expect(session.selectedProviderConversations.single.title, 'new event');
      expect(session.connectionState, DeviceConnectionState.online);
      client.stream.addError(
        const GatewayConnectionException('socket closed', retryable: true),
      );
      await pumpEventQueue();
      expect(session.connectionState, DeviceConnectionState.failed);
      expect(client.closed, isTrue);
    },
  );

  testWidgets(
    'capability loading and failure do not masquerade as unsupported',
    (tester) async {
      final client = IsolationGateway()
        ..providers = [agent('a', described: false), agent('b')];
      final pending = Completer<GatewayProvider>();
      client.describe = (_) => pending.future;
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect();
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteHomeScreen(
            sessions: [session],
            selectedIndex: 0,
            onSelectDevice: (_) {},
            onAddDevice: () {},
            onOpenSettings: () {},
          ),
        ),
      );
      await tester.pump();
      expect(find.text('智能体信息加载中'), findsOneWidget);
      expect(find.text('当前 Gateway / Provider 不支持最近会话'), findsNothing);
      pending.completeError(StateError('capabilities failed'));
      await tester.pumpAndSettle();
      expect(find.text('智能体信息加载失败'), findsOneWidget);
      expect(find.text('当前 Gateway / Provider 不支持最近会话'), findsNothing);
      expect(session.connectionState, DeviceConnectionState.online);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'removal and reinstall with the same generation fences old failures',
    () async {
      final client = IsolationGateway();
      final old = Completer<ProjectPage>();
      var first = true;
      client.projects = (id, _) {
        if (id == 'a' && first) {
          first = false;
          return old.future;
        }
        return Future.value(client.page(id, 'new installation'));
      };
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect();
      await pumpEventQueue();
      client.snapshots.add([agent('b')]);
      client.snapshots.add([agent('a'), agent('b')]);
      session.selectProvider(agent('a'));
      await pumpEventQueue();
      expect(session.selectedProviderProjects.single.name, 'new installation');
      old.completeError(StateError('retired installation error'));
      await pumpEventQueue();
      expect(
        session.providerData('a', ProviderDataKind.projects).status,
        ProviderDataStatus.ready,
      );
      expect(session.connectionState, DeviceConnectionState.online);
    },
  );

  test(
    'successful event refresh clears only that Providers business error',
    () async {
      final client = IsolationGateway();
      var fail = true;
      client.chats = (id, _) async {
        if (id == 'a' && fail) throw StateError('conversation source failed');
        return client.chatPage(id);
      };
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect();
      await pumpEventQueue();
      expect(
        session.providerData('a', ProviderDataKind.conversations).status,
        ProviderDataStatus.failed,
      );
      fail = false;
      client.emit(
        TurnUpsertedEvent(
          eventCursor: 'e1',
          turn: TurnTask(
            id: 'new-turn',
            providerId: 'a',
            conversationId: 'chat-a',
            conversationResource: const RoutedResourceId(
              providerId: 'a',
              nativeResourceId: 'chat-a',
            ),
            status: TurnStatus.completed,
            updatedAt: DateTime.utc(2026),
          ),
        ),
      );
      await pumpEventQueue();
      expect(
        session.providerData('a', ProviderDataKind.conversations).status,
        ProviderDataStatus.ready,
      );
      expect(session.selectedProviderConversations.single.id, 'chat-a');
      expect(session.connectionState, DeviceConnectionState.online);
    },
  );

  for (final width in [320.0, 1000.0]) {
    testWidgets('local error, retry and Provider switching at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 950);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = IsolationGateway()..badProject = true;
      final session = sessionFor(client);
      addTearDown(session.dispose);
      await session.connect();
      await tester.pumpWidget(
        MaterialApp(
          home: RemoteHomeScreen(
            sessions: [session],
            selectedIndex: 0,
            onSelectDevice: (_) {},
            onAddDevice: () {},
            onOpenSettings: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('项目加载失败'), findsOneWidget);
      expect(session.connectionState, DeviceConnectionState.online);
      client.badProject = false;
      Focus.of(tester.element(find.text('重试'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('项目加载失败'), findsNothing);
      await tester.tap(find.byKey(const Key('provider-b')));
      await tester.pumpAndSettle();
      expect(session.selectedProviderProjects.single.name, 'b');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
