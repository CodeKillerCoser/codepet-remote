import 'dart:async';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_session.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
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

  test('loads two cursor pages with an explicit small page limit', () async {
    final client = _FakeClient(
      const [],
      onListConversations: ({required String? cursor, required int limit}) async {
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

  test('suppresses concurrent load-more requests', () async {
    final nextPage = Completer<ConversationPage>();
    final client = _FakeClient(
      const [],
      onListConversations: ({required String? cursor, required int limit}) {
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
      onListConversations: ({required String? cursor, required int limit}) async {
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
      onListConversations: ({required String? cursor, required int limit}) {
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

  test('reconnect while online closes the old client and creates a new one', () async {
    var firstPageAttempts = 0;
    final first = _FakeClient(
      const [],
      onListConversations: ({required String? cursor, required int limit}) async {
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
      onListConversations: ({required String? cursor, required int limit}) {
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
  final resource = {
    'deviceId': hostDeviceId,
    'providerPluginId': providerPluginId,
    'providerInstanceId': providerInstanceId,
    'nativeResourceId': nativeId,
  };
  final id = resource.values.join('\u0000');
  return ConversationSummary(
    id: domainId ?? id,
    providerId: providerInstanceId,
    title: title ?? nativeId,
    status: ConversationStatus.idle,
    permissionLevel: PermissionLevel.readOnly,
    workspaceRoot: workspaceRoot,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    wireResource: resource,
  );
}

typedef _ListConversationsHandler = Future<ConversationPage> Function({
  required String? cursor,
  required int limit,
});

class _ConversationListRequest {
  const _ConversationListRequest({required this.cursor, required this.limit});

  final String? cursor;
  final int limit;
}

class _FakeClient implements GatewayClient {
  _FakeClient(
    this.values, {
    this.nextCursor,
    this.onListConversations,
  });
  final List<ConversationSummary> values;
  final String? nextCursor;
  final _ListConversationsHandler? onListConversations;
  final List<_ConversationListRequest> listRequests = [];
  final StreamController<GatewayEvent> controller = StreamController<GatewayEvent>.broadcast();
  String _cursor = 'handshake';
  bool closed = false;
  @override Stream<GatewayEvent> get events => controller.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; controller.add(event); }
  @override Future<GatewayHandshake> connect() async => const GatewayHandshake(protocolVersion: 1, serverName: 'Test', serverVersion: '1', providers: [], eventCursor: 'handshake');
  @override
  Future<ConversationPage> listConversations({
    String? providerId,
    String? cursor,
    int limit = 50,
  }) async {
    listRequests.add(_ConversationListRequest(cursor: cursor, limit: limit));
    final handler = onListConversations;
    if (handler != null) {
      return handler(cursor: cursor, limit: limit);
    }
    return ConversationPage(
      conversations: values,
      nextCursor: nextCursor,
      snapshotCursor: 'handshake',
    );
  }
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: _cursor);
  @override Future<void> close() async { closed = true; await controller.close(); }
}

class _FailingClient implements GatewayClient {
  bool closeCalled = false;
  @override Stream<GatewayEvent> get events => const Stream.empty();
  @override String? get latestEventCursor => null;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(null, events);
  @override Future<GatewayHandshake> connect() => Future.error('first connection failed');
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<void> close() async {
    closeCalled = true;
    throw StateError('close also failed');
  }
}
