import 'dart:async';

import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/sync/gateway_event_window.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('groups workspaces and sorts projects and recents', () {
    final old = _conversation('old', '/repo/a', 1000);
    final recent = _conversation('recent', '/repo/a', 3000);
    final other = _conversation('other', '/repo/b', 2000);
    final unscoped = _conversation('unscoped', null, 4000);
    final groups = groupConversationsByWorkspace([old, unscoped, other, recent]);
    expect(groups.keys, ['/repo/a', '/repo/b']);
    expect(groups['/repo/a']!.map((item) => item.id), ['recent', 'old']);
    expect(sortRecentConversations([old, recent, other]).map((item) => item.id), ['recent', 'other', 'old']);
  });

  test('uses stable routed tie-breakers for conversations and projects', () {
    final beta = _conversation('beta', '/repo/a', 3000);
    final alpha = _conversation('alpha', '/repo/a', 3000);
    final otherProject = _conversation('other', '/repo/b', 3000);

    expect(
      sortRecentConversations([beta, alpha]).map((item) => item.id),
      ['alpha', 'beta'],
    );

    final groups = groupConversationsByWorkspace([
      otherProject,
      beta,
      alpha,
    ]);
    expect(groups.keys, ['/repo/a', '/repo/b']);
    expect(groups['/repo/a']!.map((item) => item.id), ['alpha', 'beta']);
  });

  test('groups only by the Host project projection and preserves routed conversations', () {
    final codex = _routedConversation(
      domainId: 'shared-domain-id',
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/logical/project',
      updatedAt: 2000,
    );
    final claude = _routedConversation(
      domainId: 'shared-domain-id',
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.claude',
      providerInstanceId: 'claude-work',
      workspaceRoot: '/logical/project',
      updatedAt: 1000,
    );
    final duplicate = _routedConversation(
      domainId: 'shared-domain-id',
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/logical/project',
      updatedAt: 1500,
    );
    final otherHost = _routedConversation(
      domainId: 'shared-domain-id',
      hostDeviceId: 'host-two',
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/logical/project',
      updatedAt: 1000,
    );

    final projects = groupConversationsByProject(
      hostDeviceId: 'host-one',
      values: [claude, duplicate, codex],
    );

    expect(projects, hasLength(1));
    expect(projects.single.workspaceRoot, '/logical/project');
    expect(projects.single.key, 'host-one\u0000/logical/project');
    expect(
      projects.single.conversations.map((item) => item.id),
      [codex.id, claude.id],
    );
    expect(
      deduplicateRoutedConversations([codex, claude, otherHost]),
      hasLength(3),
    );
  });

  test('an equal-timestamp projection replaces the earlier routed value', () {
    final earlier = _routedConversation(
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/logical/project',
      updatedAt: 2000,
      title: '旧标题',
    );
    final later = _routedConversation(
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/logical/project',
      updatedAt: 2000,
      title: '新标题',
    );

    expect(
      deduplicateRoutedConversations([earlier, later]).single.title,
      '新标题',
    );
  });

  test('loads two cursor pages with an explicit small page limit', () async {
    final client = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [_conversation('first', '/repo', 1000)],
            nextCursor: 'page-2',
            snapshotCursor: 'handshake',
          );
        }
        expect(cursor, 'page-2');
        return ConversationPage(
          conversations: [_conversation('second', '/repo', 2000)],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('paged'),
      clientFactory: () => client,
    );

    await session.connect();

    expect(client.listRequests, hasLength(1));
    expect(client.listRequests.single.cursor, isNull);
    expect(
      client.listRequests.single.limit,
      DeviceSession.conversationPageSize,
    );
    expect(DeviceSession.conversationPageSize, 20);
    expect(session.canLoadMoreConversations, isTrue);

    await session.loadMoreConversations();

    expect(
      session.conversations.map((conversation) => conversation.id),
      ['second', 'first'],
    );
    expect(client.listRequests, hasLength(2));
    expect(client.listRequests.last.cursor, 'page-2');
    expect(client.listRequests.last.limit, DeviceSession.conversationPageSize);
    expect(session.canLoadMoreConversations, isFalse);

    await session.loadMoreConversations();
    expect(client.listRequests, hasLength(2));
    session.dispose();
  });

  test('keeps independent cursors and merges routed Provider pages', () async {
    final client = _FakeClient(
      const [],
      providers: const [_listProvider, _secondaryListProvider],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) async {
        if (route == _primaryRoute && cursor == null) {
          return ConversationPage(
            conversations: [
              _routedConversation(
                nativeId: 'shared',
                providerPluginId: route.providerPluginId,
                providerInstanceId: route.providerInstanceId,
                workspaceRoot: '/repo',
                updatedAt: 1000,
              ),
              _routedConversation(
                nativeId: 'alpha',
                providerPluginId: route.providerPluginId,
                providerInstanceId: route.providerInstanceId,
                workspaceRoot: '/repo',
                updatedAt: 2000,
              ),
            ],
            nextCursor: 'codex-next',
            snapshotCursor: 'handshake',
          );
        }
        if (route == _secondaryRoute && cursor == null) {
          return ConversationPage(
            conversations: [
              _routedConversation(
                nativeId: 'beta',
                providerPluginId: route.providerPluginId,
                providerInstanceId: route.providerInstanceId,
                workspaceRoot: '/repo',
                updatedAt: 3000,
              ),
            ],
            snapshotCursor: 'handshake',
          );
        }
        expect(route, _primaryRoute);
        expect(cursor, 'codex-next');
        return ConversationPage(
          conversations: [
            _routedConversation(
              nativeId: 'shared',
              providerPluginId: route.providerPluginId,
              providerInstanceId: route.providerInstanceId,
              workspaceRoot: '/repo',
              updatedAt: 4000,
              title: 'new shared',
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('multi-route'),
      clientFactory: () => client,
    );

    await session.connect();

    expect(client.listRequests.map((request) => request.route), [
      _primaryRoute,
      _secondaryRoute,
    ]);
    expect(
      session.conversations.map((conversation) => conversation.title),
      ['beta', 'alpha', 'shared'],
    );
    expect(session.canLoadMoreConversations, isTrue);

    await session.loadMoreConversations();

    expect(client.listRequests, hasLength(3));
    expect(client.listRequests.last.route, _primaryRoute);
    expect(client.listRequests.last.cursor, 'codex-next');
    expect(session.conversations, hasLength(3));
    expect(session.conversations.first.title, 'new shared');
    expect(session.canLoadMoreConversations, isFalse);
    session.dispose();
  });

  test('marks a loaded count approximate until every route is exhausted', () async {
    final client = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [
              for (var index = 0; index < 20; index++)
                _routedConversation(
                  nativeId: 'initial-$index',
                  providerPluginId: route.providerPluginId,
                  providerInstanceId: route.providerInstanceId,
                  workspaceRoot: '/repo',
                  updatedAt: 1000 - index,
                ),
            ],
            nextCursor: 'next',
            snapshotCursor: 'handshake',
          );
        }
        return ConversationPage(
          conversations: [
            _routedConversation(
              nativeId: 'last',
              providerPluginId: route.providerPluginId,
              providerInstanceId: route.providerInstanceId,
              workspaceRoot: '/repo',
              updatedAt: 1,
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('count'),
      clientFactory: () => client,
    );

    await session.connect();
    expect(session.conversationCountLabel, '20+');

    await session.loadMoreConversations();
    expect(session.conversationCountLabel, '21');
    session.dispose();
  });

  test('suppresses concurrent load-more requests', () async {
    final nextPage = Completer<ConversationPage>();
    final client = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) {
        if (cursor == null) {
          return Future.value(
            const ConversationPage(
              conversations: [],
              nextCursor: 'page-2',
              snapshotCursor: 'handshake',
            ),
          );
        }
        return nextPage.future;
      },
    );
    final session = DeviceSession(
      device: _device('concurrent'),
      clientFactory: () => client,
    );
    await session.connect();

    final firstRequest = session.loadMoreConversations();
    final duplicateRequest = session.loadMoreConversations();
    await duplicateRequest;

    expect(session.isLoadingMoreConversations, isTrue);
    expect(client.listRequests, hasLength(2));

    nextPage.complete(
      ConversationPage(
        conversations: [_conversation('next', '/repo', 2000)],
        snapshotCursor: 'handshake',
      ),
    );
    await firstRequest;

    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.conversations.single.id, 'next');
    session.dispose();
  });

  test('keeps the page cursor and existing data after failure for retry', () async {
    var nextPageAttempts = 0;
    final client = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [_conversation('first', '/repo', 1000)],
            nextCursor: 'retry-page',
            snapshotCursor: 'handshake',
          );
        }
        nextPageAttempts++;
        if (nextPageAttempts == 1) {
          throw StateError('page failed');
        }
        return ConversationPage(
          conversations: [_conversation('recovered', '/repo', 2000)],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('retry-page'),
      clientFactory: () => client,
    );
    await session.connect();

    await session.loadMoreConversations();

    expect(session.conversations.single.id, 'first');
    expect(session.canLoadMoreConversations, isTrue);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, contains('page failed'));

    await session.loadMoreConversations();

    expect(nextPageAttempts, 2);
    expect(session.loadMoreError, isNull);
    expect(session.canLoadMoreConversations, isFalse);
    expect(
      session.conversations.map((conversation) => conversation.id),
      ['recovered', 'first'],
    );
    session.dispose();
  });

  test('a stale page cannot overwrite a newer routed event', () async {
    final nextPage = Completer<ConversationPage>();
    final client = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) {
        if (cursor == null) {
          return Future.value(
            const ConversationPage(
              conversations: [],
              nextCursor: 'page-2',
              snapshotCursor: 'handshake',
            ),
          );
        }
        return nextPage.future;
      },
    );
    final session = DeviceSession(
      device: _device('event-race'),
      clientFactory: () => client,
    );
    await session.connect();

    final request = session.loadMoreConversations();
    client.emit(
      ConversationUpsertedEvent(
        eventCursor: 'event-2',
        conversation: _routedConversation(
          nativeId: 'shared',
          providerPluginId: 'dev.codepet.codex',
          providerInstanceId: 'codex-work',
          workspaceRoot: '/repo',
          updatedAt: 3000,
          title: 'new event',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    nextPage.complete(
      ConversationPage(
        conversations: [
          _routedConversation(
            nativeId: 'shared',
            providerPluginId: 'dev.codepet.codex',
            providerInstanceId: 'codex-work',
            workspaceRoot: '/repo',
            updatedAt: 2000,
            title: 'stale page',
          ),
        ],
        snapshotCursor: 'handshake',
      ),
    );
    await request;

    expect(session.conversations, hasLength(1));
    expect(session.conversations.single.title, 'new event');
    expect(
      session.conversations.single.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
    );
    session.dispose();
  });

  test('a routed event refreshes title without regressing list ordering time', () async {
    final original = _routedConversation(
      nativeId: 'renamed',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/repo',
      updatedAt: 3000,
      title: '旧标题',
    );
    final client = _FakeClient([original]);
    final session = DeviceSession(
      device: _device('title-event'),
      clientFactory: () => client,
    );
    await session.connect();

    client.emit(
      ConversationUpsertedEvent(
        eventCursor: 'event-2',
        conversation: _routedConversation(
          nativeId: 'renamed',
          providerPluginId: 'dev.codepet.codex',
          providerInstanceId: 'codex-work',
          workspaceRoot: '/repo',
          updatedAt: 2000,
          title: '新标题',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.title, '新标题');
    expect(session.conversations.single.updatedAt, original.updatedAt);
    session.dispose();
  });

  test('activity marks a conversation unread and metadata events preserve it',
      () async {
    final conversation = _routedConversation(
      nativeId: 'unread-thread',
      providerPluginId: _primaryRoute.providerPluginId,
      providerInstanceId: _primaryRoute.providerInstanceId,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    final client = _FakeClient([conversation]);
    final session = DeviceSession(
      device: _device('unread-event'),
      clientFactory: () => client,
    );
    await session.connect();

    client.emit(ConversationActivityChangedEvent(
      eventCursor: 'activity-event',
      conversationId: conversationRoutingKey(conversation),
      activityVersion: 'activity-1',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.readState.unread, isTrue);
    expect(
      session.conversations.single.readState.activityVersion,
      'activity-1',
    );

    client.emit(ConversationUpsertedEvent(
      eventCursor: 'metadata-event',
      conversation: _routedConversation(
        nativeId: 'unread-thread',
        providerPluginId: _primaryRoute.providerPluginId,
        providerInstanceId: _primaryRoute.providerInstanceId,
        workspaceRoot: '/repo',
        updatedAt: 2000,
        title: '新标题',
      ),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.title, '新标题');
    expect(session.conversations.single.readState.unread, isTrue);
    session.dispose();
  });

  test('turn events keep the conversation list running state live', () async {
    final conversation = _routedConversation(
      nativeId: 'live-thread',
      providerPluginId: _primaryRoute.providerPluginId,
      providerInstanceId: _primaryRoute.providerInstanceId,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    final client = _FakeClient([conversation]);
    final session = DeviceSession(
      device: _device('live-turn'),
      clientFactory: () => client,
    );
    await session.connect();

    client.emit(TurnUpsertedEvent(
      eventCursor: 'running',
      turn: _turnFor(conversation, TurnStatus.running, 2000),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.status, ConversationStatus.running);
    expect(session.conversations.single.activeTurn?.status, TurnStatus.running);

    client.emit(TurnOutputDeltaEvent(
      eventCursor: 'delta-1',
      providerId: conversation.providerId,
      conversationId: conversationRoutingKey(conversation),
      turnId: 'turn-live',
      itemId: 'assistant',
      contentId: 'assistant:text',
      kind: 'text',
      delta: '实时',
    ));
    client.emit(TurnOutputDeltaEvent(
      eventCursor: 'delta-2',
      providerId: conversation.providerId,
      conversationId: conversationRoutingKey(conversation),
      turnId: 'turn-live',
      itemId: 'assistant',
      contentId: 'assistant:text',
      kind: 'text',
      delta: '内容',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.preview, '实时内容');

    client.emit(TurnUpsertedEvent(
      eventCursor: 'completed',
      turn: _turnFor(conversation, TurnStatus.completed, 3000),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.status, ConversationStatus.idle);
    expect(session.conversations.single.activeTurn, isNull);
    expect(
      session.conversations.single.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
    );
    session.dispose();
  });

  testWidgets('coalesces a burst of output deltas into one frame notification',
      (tester) async {
    final conversation = _routedConversation(
      nativeId: 'coalesced-thread',
      providerPluginId: _primaryRoute.providerPluginId,
      providerInstanceId: _primaryRoute.providerInstanceId,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    final client = _FakeClient([conversation]);
    final session = DeviceSession(
      device: _device('coalesced-deltas'),
      clientFactory: () => client,
    );
    await session.connect();
    var sessionNotifications = 0;
    session.addListener(() => sessionNotifications++);

    for (var index = 0; index < 20; index++) {
      client.emit(TurnOutputDeltaEvent(
        eventCursor: 'delta-$index',
        providerId: conversation.providerId,
        conversationId: conversationRoutingKey(conversation),
        turnId: 'turn-live',
        itemId: 'assistant',
        contentId: 'assistant:text',
        kind: 'text',
        delta: '$index',
      ));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(sessionNotifications, 1);
    expect(session.conversations.single.preview, contains('19'));
    session.dispose();
  });

  test('an unknown turn event refreshes its Provider conversation list', () async {
    late ConversationSummary discovered;
    var listCalls = 0;
    final client = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) async {
        listCalls++;
        if (listCalls == 1) {
          return const ConversationPage(
            conversations: [],
            snapshotCursor: 'handshake',
          );
        }
        return ConversationPage(
          conversations: [discovered],
          snapshotCursor: 'running',
        );
      },
    );
    final session = DeviceSession(
      device: _device('discover-from-turn'),
      clientFactory: () => client,
    );
    await session.connect();
    discovered = _routedConversation(
      nativeId: 'new-thread',
      providerPluginId: _primaryRoute.providerPluginId,
      providerInstanceId: _primaryRoute.providerInstanceId,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );

    client.emit(TurnUpsertedEvent(
      eventCursor: 'running',
      turn: _turnFor(discovered, TurnStatus.running, 2000),
    ));
    await pumpEventQueue();

    expect(listCalls, 2);
    expect(session.conversations.single.id, discovered.id);
    expect(session.conversations.single.status, ConversationStatus.running);
    session.dispose();
  });

  test('unknown turn events arriving during refresh are drained', () async {
    final firstRefresh = Completer<ConversationPage>();
    final firstRefreshStarted = Completer<void>();
    late ConversationSummary first;
    late ConversationSummary second;
    var listCalls = 0;
    final client = _FakeClient(
      const [],
      onListConversations: ({
        required GatewayProviderRoute route,
        required String? cursor,
        required int limit,
      }) {
        listCalls++;
        if (listCalls == 1) {
          return Future.value(const ConversationPage(
            conversations: [],
            snapshotCursor: 'handshake',
          ));
        }
        if (listCalls == 2) {
          firstRefreshStarted.complete();
          return firstRefresh.future;
        }
        return Future.value(ConversationPage(
          conversations: [second],
          snapshotCursor: 'second-running',
        ));
      },
    );
    final session = DeviceSession(
      device: _device('drain-turn-refresh'),
      clientFactory: () => client,
    );
    await session.connect();
    first = _routedConversation(
      nativeId: 'first-during-refresh',
      providerPluginId: _primaryRoute.providerPluginId,
      providerInstanceId: _primaryRoute.providerInstanceId,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    second = _routedConversation(
      nativeId: 'second-during-refresh',
      providerPluginId: _primaryRoute.providerPluginId,
      providerInstanceId: _primaryRoute.providerInstanceId,
      workspaceRoot: '/repo',
      updatedAt: 2000,
    );

    client.emit(TurnUpsertedEvent(
      eventCursor: 'first-running',
      turn: _turnFor(first, TurnStatus.running, 3000),
    ));
    await firstRefreshStarted.future;
    client.emit(TurnUpsertedEvent(
      eventCursor: 'second-running',
      turn: _turnFor(second, TurnStatus.running, 4000),
    ));
    firstRefresh.complete(ConversationPage(
      conversations: [first],
      snapshotCursor: 'first-running',
    ));
    await pumpEventQueue(times: 4);

    expect(listCalls, 3);
    expect(
      session.conversations.map((conversation) => conversation.title),
      containsAll(['first-during-refresh', 'second-during-refresh']),
    );
    expect(
      session.conversations.map((conversation) => conversation.status),
      everyElement(ConversationStatus.running),
    );
    session.dispose();
  });

  test('sessions isolate projections and disconnect clears runtime data', () async {
    final firstClient = _FakeClient([_conversation('first', '/one', 1000)]);
    final secondClient = _FakeClient([_conversation('second', '/two', 2000)]);
    final first = DeviceSession(device: _device('one'), clientFactory: () => firstClient);
    final second = DeviceSession(device: _device('two'), clientFactory: () => secondClient);
    await Future.wait([first.connect(), second.connect()]);
    expect(first.conversations.single.id, 'first');
    expect(second.conversations.single.id, 'second');
    firstClient.emit(ConversationUpsertedEvent(eventCursor: 'event-2', conversation: _conversation('first-new', '/one', 3000)));
    await Future<void>.delayed(Duration.zero);
    expect(first.conversations.map((item) => item.id), contains('first-new'));
    expect(second.conversations.single.id, 'second');
    await first.disconnect();
    expect(first.conversations, isEmpty);
    expect(first.handshake, isNull);
    expect(second.conversations.single.id, 'second');
    second.dispose();
  });

  test('runtime leases expire when the session reconnects or disconnects', () async {
    final firstClient = _FakeClient(const []);
    final secondClient = _FakeClient(const []);
    final clients = [firstClient, secondClient];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('runtime-lease'),
      clientFactory: () => clients[factoryCalls++],
    );

    await session.connect();
    final firstLease = session.runtimeLease!;
    expect(session.ownsRuntimeLease(firstLease), isTrue);

    await session.connect();
    final secondLease = session.runtimeLease!;
    expect(session.ownsRuntimeLease(firstLease), isFalse);
    expect(session.ownsRuntimeLease(secondLease), isTrue);
    expect(firstLease.sameRuntime(secondLease), isFalse);

    await session.disconnect();
    expect(session.runtimeLease, isNull);
    expect(session.ownsRuntimeLease(secondLease), isFalse);
    session.dispose();
  });

  test('failed connect discards client and retry creates a fresh client', () async {
    final failed = _FailingClient();
    final successful = _FakeClient([_conversation('recovered', '/repo', 1000)]);
    final clients = <GatewayClient>[failed, successful];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('retry'),
      clientFactory: () {
        final client = clients[factoryCalls];
        factoryCalls++;
        return client;
      },
    );

    await session.connect();
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, 'first connection failed');
    expect(session.handshake, isNull);
    expect(session.conversations, isEmpty);
    expect(failed.closeCalled, isTrue);

    await session.connect();
    expect(factoryCalls, 2);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.error, isNull);
    expect(session.conversations.single.id, 'recovered');
    session.dispose();
  });

  test('bounded candidate failure leaves connecting and exposes retry state', () async {
    final client = _ControlledConnectClient();
    final session = DeviceSession(
      device: _device('bounded-connect-failure'),
      clientFactory: () => client,
      autoReconnect: false,
    );

    final attempt = session.connect();
    expect(session.connectionState, DeviceConnectionState.connecting);
    await client.connectStarted.future;
    client.connectResult.completeError(
      const GatewayConnectionException(
        'all Gateway candidates timed out',
        retryable: true,
      ),
    );

    await attempt.timeout(const Duration(seconds: 1));

    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, contains('timed out'));
    expect(client.closeCalled, isTrue);
    session.dispose();
  });

  test('failed connect automatically retries with a fresh client', () async {
    final failed = _FailingClient();
    final successful = _FakeClient([
      _conversation('automatically-recovered', '/repo', 1000),
    ]);
    final clients = <GatewayClient>[failed, successful];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('automatic-retry'),
      clientFactory: () => clients[factoryCalls++],
      reconnectDelays: const [Duration.zero],
    );

    await session.connect();
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(failed.closeCalled, isTrue);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'automatically-recovered');
    session.dispose();
  });

  test('late failed cleanup cannot schedule over a manual healthy connection', () async {
    final failed = _DelayedCleanupFailingClient();
    final healthy = _FakeClient([
      _conversation('manual-recovery', '/repo', 1000),
    ]);
    final clients = <GatewayClient>[failed, healthy];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('late-failure-manual-recovery'),
      clientFactory: () => clients[factoryCalls++],
      reconnectDelays: const [Duration.zero],
    );

    final failedAttempt = session.connect();
    await failed.closeStarted.future;
    await session.connect();

    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'manual-recovery');

    failed.finishClose();
    await failedAttempt;
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(healthy.closed, isFalse);
    expect(session.connectionState, DeviceConnectionState.online);
    session.dispose();
  });

  test('explicit disconnect cancels a scheduled automatic retry', () async {
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('cancel-automatic-retry'),
      clientFactory: () {
        factoryCalls++;
        return _FailingClient();
      },
      reconnectDelays: const [Duration.zero],
    );

    await session.connect();
    await session.disconnect();
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.offline);
    session.dispose();
  });

  test('disconnect fences a retryable failure still cleaning up', () async {
    final failed = _DelayedCleanupFailingClient();
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('disconnect-during-cleanup'),
      clientFactory: () {
        factoryCalls++;
        return failed;
      },
      reconnectDelays: const [Duration.zero],
    );

    final failedAttempt = session.connect();
    await failed.closeStarted.future;
    await session.disconnect();
    failed.finishClose();
    await failedAttempt;
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.offline);
    session.dispose();
  });

  test('dispose fences a retryable failure still cleaning up', () async {
    final failed = _DelayedCleanupFailingClient();
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('dispose-during-cleanup'),
      clientFactory: () {
        factoryCalls++;
        return failed;
      },
      reconnectDelays: const [Duration.zero],
    );

    final failedAttempt = session.connect();
    await failed.closeStarted.future;
    session.dispose();
    failed.finishClose();
    await failedAttempt;
    await pumpEventQueue();

    expect(factoryCalls, 1);
  });

  test('non-retryable connection failure does not loop in the background', () async {
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('rejected-credential'),
      clientFactory: () {
        factoryCalls++;
        return _NonRetryableClient();
      },
      reconnectDelays: const [Duration.zero],
    );

    await session.connect();
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, 'credential rejected');

    await session.connect();
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(session.connectionState, DeviceConnectionState.failed);
    session.dispose();
  });

  test('reconnect while online closes the old client and creates a new one', () async {
    var firstPageAttempts = 0;
    final first = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [_conversation('old', '/repo', 1000)],
            nextCursor: 'retry-page',
            snapshotCursor: 'handshake',
          );
        }
        firstPageAttempts++;
        throw StateError('old page failure');
      },
    );
    final second = _FakeClient([_conversation('new', '/repo', 2000)]);
    final clients = [first, second];
    var calls = 0;
    final session = DeviceSession(
      device: _device('reconnect'),
      clientFactory: () => clients[calls++],
    );
    await session.connect();
    await session.loadMoreConversations();
    expect(firstPageAttempts, 1);
    expect(session.loadMoreError, isNotNull);
    expect(session.canLoadMoreConversations, isTrue);

    await session.connect();

    expect(calls, 2);
    expect(first.closed, isTrue);
    expect(session.conversations.single.id, 'new');
    expect(session.canLoadMoreConversations, isFalse);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, isNull);
    session.dispose();
  });

  test('disconnect resets pagination and ignores a late page response', () async {
    final nextPage = Completer<ConversationPage>();
    final client = _FakeClient(
      const [],
      onListConversations: ({required GatewayProviderRoute route, required String? cursor, required int limit}) {
        if (cursor == null) {
          return Future.value(
            ConversationPage(
              conversations: [_conversation('first', '/repo', 1000)],
              nextCursor: 'page-2',
              snapshotCursor: 'handshake',
            ),
          );
        }
        return nextPage.future;
      },
    );
    final session = DeviceSession(
      device: _device('disconnect-page'),
      clientFactory: () => client,
    );
    await session.connect();
    final request = session.loadMoreConversations();
    expect(session.isLoadingMoreConversations, isTrue);

    await session.disconnect();

    expect(session.conversations, isEmpty);
    expect(session.canLoadMoreConversations, isFalse);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, isNull);

    nextPage.complete(
      ConversationPage(
        conversations: [_conversation('late', '/repo', 2000)],
        snapshotCursor: 'handshake',
      ),
    );
    await request;

    expect(session.connectionState, DeviceConnectionState.offline);
    expect(session.conversations, isEmpty);
    session.dispose();
  });

  test('event stream failure clears the complete runtime projection', () async {
    final client = _FakeClient(
      [_conversation('stale', '/repo', 1000)],
      nextCursor: 'page-2',
    );
    final session = DeviceSession(device: _device('lost'), clientFactory: () => client);
    await session.connect();
    expect(session.canLoadMoreConversations, isTrue);
    client.controller.addError(StateError('socket lost'));
    await Future<void>.delayed(Duration.zero);
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.handshake, isNull);
    expect(session.conversations, isEmpty);
    expect(session.canLoadMoreConversations, isFalse);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, isNull);
    expect(client.closed, isTrue);
    session.dispose();
  });

  test('event stream failure automatically reconnects with a fresh client', () async {
    final disconnected = _FakeClient([
      _conversation('stale', '/repo', 1000),
    ]);
    final recovered = _FakeClient([
      _conversation('fresh', '/repo', 2000),
    ]);
    final clients = <GatewayClient>[disconnected, recovered];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('network-recovery'),
      clientFactory: () => clients[factoryCalls++],
      reconnectDelays: const [Duration.zero],
    );
    await session.connect();

    disconnected.controller.addError(const GatewayConnectionException(
      'socket lost',
      retryable: true,
    ));
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(disconnected.closed, isTrue);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'fresh');
    session.dispose();
  });

  test('re-pairing the same device replaces and disposes its old session', () async {
    final oldClient = _FakeClient(const []);
    final replacementClient = _FakeClient(const []);
    final sessions = [DeviceSession(device: _device('same'), clientFactory: () => oldClient)];
    await sessions.single.connect();
    final replacement = DeviceSession(device: _device('same'), clientFactory: () => replacementClient);
    final index = await replaceDeviceSession(sessions, replacement);
    expect(index, 0);
    expect(sessions, [replacement]);
    expect(oldClient.closed, isTrue);
    replacement.dispose();
  });
}

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
  String hostDeviceId = 'host-one',
  required String nativeId,
  required String providerPluginId,
  required String providerInstanceId,
  required String workspaceRoot,
  required int updatedAt,
  String? title,
}) {
  final route = GatewayProviderRoute(
    deviceId: hostDeviceId,
    providerPluginId: providerPluginId,
    providerInstanceId: providerInstanceId,
  );
  final resource = RoutedResourceId(route: route, nativeResourceId: nativeId);
  final id = resource.key;
  return ConversationSummary(
    id: domainId ?? id,
    providerId: providerInstanceId,
    title: title ?? nativeId,
    status: ConversationStatus.idle,
    permissionLevel: PermissionLevel.readOnly,
    workspaceRoot: workspaceRoot,
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
    route: conversationResource.route,
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
  required GatewayProviderRoute route,
  required String? cursor,
  required int limit,
});

class _ConversationListRequest {
  const _ConversationListRequest({
    required this.route,
    required this.cursor,
    required this.limit,
  });

  final GatewayProviderRoute route;
  final String? cursor;
  final int limit;
}

class _FakeClient implements GatewayClient {
  _FakeClient(
    this.values, {
    this.nextCursor,
    this.onListConversations,
    this.providers = const [_listProvider],
  });
  final List<ConversationSummary> values;
  final String? nextCursor;
  final _ListConversationsHandler? onListConversations;
  final List<GatewayProvider> providers;
  final List<_ConversationListRequest> listRequests = [];
  final StreamController<GatewayEvent> controller = StreamController<GatewayEvent>.broadcast();
  String _cursor = 'handshake';
  bool closed = false;
  @override Stream<GatewayEvent> get events => controller.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; controller.add(event); }
  @override Future<GatewayHandshake> connect() async => GatewayHandshake(protocolVersion: 1, serverName: 'Test', serverVersion: '1', providers: providers, eventCursor: 'handshake');
  @override
  Future<ConversationPage> listConversations({
    required GatewayProviderRoute route,
    String? cursor,
    int limit = 50,
  }) async {
    listRequests.add(_ConversationListRequest(
      route: route,
      cursor: cursor,
      limit: limit,
    ));
    final handler = onListConversations;
    if (handler != null) {
      return handler(route: route, cursor: cursor, limit: limit);
    }
    return ConversationPage(
      conversations: values,
      nextCursor: nextCursor,
      snapshotCursor: 'handshake',
    );
  }
  @override Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: _cursor);
  @override Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) async => const ConversationInteraction(selection: TurnSendSelection());
  @override Future<ConversationSummary> createConversation({required GatewayProviderRoute route, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode}) => throw UnimplementedError();
  @override Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();
  @override Future<void> close() async { closed = true; await controller.close(); }
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
  @override Future<ConversationPage> listConversations({required GatewayProviderRoute route, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<ConversationSummary> createConversation({required GatewayProviderRoute route, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode}) => throw StateError('not reached');
  @override Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw StateError('not reached');
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

const _primaryRoute = GatewayProviderRoute(
  deviceId: 'host-one',
  providerPluginId: 'dev.codepet.codex',
  providerInstanceId: 'codex-work',
);

const _listProvider = GatewayProvider(
  route: _primaryRoute,
  providerType: 'dev.codepet.codex',
  displayName: 'Codex Work',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'codex', displayName: 'Codex'),
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.get'],
  ),
);

const _secondaryRoute = GatewayProviderRoute(
  deviceId: 'host-one',
  providerPluginId: 'dev.codepet.claude',
  providerInstanceId: 'claude-work',
);

const _secondaryListProvider = GatewayProvider(
  route: _secondaryRoute,
  providerType: 'dev.codepet.claude',
  displayName: 'Claude Work',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'claude', displayName: 'Claude'),
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
