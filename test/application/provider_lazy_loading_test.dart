import 'dart:async';

import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/ports/recent_conversation_gateway.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/features/home/remote_home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recent_gateway.dart';

GatewayProvider provider(String id) => GatewayProvider(
  id: id,
  displayName: id,
  status: ProviderStatus.ready,
  capabilities: const GatewayCapabilities(
    revision: 'v1',
    methods: ['project.list', 'conversation.list', 'conversation.recent'],
  ),
);

class LazyGateway extends RecentGatewayFake
    implements ProviderSnapshotGatewayClient {
  final snapshots = StreamController<List<GatewayProvider>>.broadcast();
  final calls = <(String, String, String?)>[];
  Completer<ConversationPage>? pendingConversation;
  @override
  Stream<List<GatewayProvider>> get providerSnapshots => snapshots.stream;
  @override
  Future<GatewayHandshake> connect() async => GatewayHandshake(
    protocolVersion: 1,
    providers: [provider('a'), provider('b')],
    eventCursor: cursor,
    deviceDescriptor: const DeviceDescriptor(
      deviceName: 'Test',
      operatingSystem: 'Test',
      systemVersion: '1',
    ),
  );
  @override
  Future<ProjectPage> listProjects({
    required String providerId,
    String? cursor,
    int limit = 50,
  }) async {
    calls.add(('projects', providerId, cursor));
    return ProjectPage(projects: const [], snapshotCursor: this.cursor);
  }

  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    calls.add(('chat', providerId, cursor));
    final pending = pendingConversation;
    pendingConversation = null;
    if (pending != null) return pending.future;
    return ConversationPage(
      conversations: const [],
      snapshotCursor: this.cursor,
      nextCursor: cursor == null ? 'chat-next' : null,
    );
  }

  @override
  Future<RecentConversationPage> recentConversations({
    required String providerId,
    String? cursor,
    int limit = 20,
  }) async {
    calls.add(('recent', providerId, cursor));
    return RecentConversationPage(
      conversations: const [],
      revision: this.cursor,
      snapshotCursor: this.cursor,
      nextCursor: cursor == null ? 'recent-next' : null,
    );
  }

  void emit(GatewayEvent Function(String) event) {
    cursor = 'e${int.parse(cursor.substring(1)) + 1}';
    stream.add(event(cursor));
  }

  void invalidate(String id) {
    emit(
      (cursor) => RecentConversationsChangedEvent(
        eventCursor: cursor,
        providerId: id,
        revision: cursor,
      ),
    );
    emit(
      (cursor) => ProjectChangedEvent(
        eventCursor: cursor,
        project: RoutedResourceId(providerId: id, nativeResourceId: 'project'),
        changeType: ProjectChangeType.updated,
      ),
    );
    emit(
      (cursor) => TurnUpsertedEvent(
        eventCursor: cursor,
        turn: TurnTask(
          id: 'turn',
          providerId: id,
          conversationId: 'unknown',
          status: TurnStatus.completed,
          updatedAt: DateTime.utc(2026),
          conversationResource: RoutedResourceId(
            providerId: id,
            nativeResourceId: 'unknown',
          ),
        ),
      ),
    );
  }

  @override
  Future<void> close() async {
    await snapshots.close();
    await super.close();
  }
}

void main() {
  late LazyGateway client;
  late DeviceSession session;
  setUp(() {
    client = LazyGateway();
    session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'lazy',
        displayName: 'Lazy',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: () => client,
    );
  });
  tearDown(() => session.dispose());

  for (final width in [360.0, 1000.0]) {
    testWidgets('home tab loads its provider at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
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
      expect(client.calls.every((call) => call.$2 == 'a'), isTrue);
      final tab = find.byKey(const Key('provider-b'));
      expect(tab.hitTestable(), findsOneWidget);
      await tester.tap(tab);
      await tester.pumpAndSettle();
      expect(session.selectedProviderId, 'b');
      expect(tester.widget<ChoiceChip>(tab).selected, isTrue);
      expect(
        client.calls
            .where((call) => call.$2 == 'b')
            .map((call) => call.$1)
            .toSet(),
        {'projects', 'chat', 'recent'},
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  test(
    'connect loads only selected tab; switching retains independent pages',
    () async {
      await session.connect();
      await pumpEventQueue();
      expect(client.calls, [
        ('projects', 'a', null),
        ('chat', 'a', null),
        ('recent', 'a', null),
      ]);
      await session.selectedProviderRecent!.loadMore();
      await session.loadMoreSelectedProviderConversations();
      session.selectProvider(provider('b'));
      await pumpEventQueue();
      expect(
        client.calls
            .where((call) => call.$2 == 'b')
            .map((call) => call.$1)
            .toSet(),
        {'projects', 'chat', 'recent'},
      );
      final count = client.calls.length;
      session.selectProvider(provider('a'));
      await pumpEventQueue();
      expect(client.calls, hasLength(count));
      expect(session.selectedProviderRecent!.canLoadMore, isFalse);
      expect(session.canLoadMoreSelectedProviderConversations, isFalse);
    },
  );

  test(
    'unselected provider events defer list requests until selection',
    () async {
      await session.connect();
      await pumpEventQueue();
      client.invalidate('b');
      client.emit(
        (cursor) => GatewayProviderChangedEvent(
          eventCursor: cursor,
          provider: provider('b'),
        ),
      );
      await pumpEventQueue();
      expect(client.calls.every((call) => call.$2 == 'a'), isTrue);
      session.selectProvider(provider('b'));
      await pumpEventQueue();
      final count = client.calls.length;
      client.invalidate('a');
      await pumpEventQueue();
      expect(client.calls, hasLength(count));
      session.selectProvider(provider('a'));
      await pumpEventQueue();
      expect(
        client.calls.skip(count).map((call) => (call.$1, call.$2)).toSet(),
        {('projects', 'a'), ('chat', 'a'), ('recent', 'a')},
      );
    },
  );

  test('rapid switching shares pending first-page load', () async {
    await session.connect();
    final pending = Completer<ConversationPage>();
    client.pendingConversation = pending;
    session.selectProvider(provider('b'));
    session.selectProvider(provider('a'));
    session.selectProvider(provider('b'));
    await pumpEventQueue();
    expect(
      client.calls.where((call) => call.$1 == 'chat' && call.$2 == 'b'),
      hasLength(1),
    );
    pending.complete(
      ConversationPage(conversations: const [], snapshotCursor: client.cursor),
    );
    await pumpEventQueue();
  });

  test('provider removal loads the newly selected fallback', () async {
    await session.connect();
    client.snapshots.add([provider('b')]);
    await pumpEventQueue();
    expect(session.selectedProviderId, 'b');
    expect(
      client.calls
          .where((call) => call.$2 == 'b')
          .map((call) => call.$1)
          .toSet(),
      {'projects', 'chat', 'recent'},
    );
  });

  test('reconnect loads only the retained selection', () async {
    await session.connect();
    session.selectProvider(provider('b'));
    await pumpEventQueue();
    await session.disconnect();
    client = LazyGateway();
    await session.connect();
    await pumpEventQueue();
    expect(session.selectedProviderId, 'b');
    expect(client.calls.map((call) => call.$2).toSet(), {'b'});
    expect(client.calls.map((call) => call.$1).toSet(), {
      'projects',
      'chat',
      'recent',
    });
  });
}
