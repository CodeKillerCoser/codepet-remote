import 'package:codepet_remote/application/conversations/recent_conversation_controller.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/application/ports/recent_conversation_gateway.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recent_gateway.dart';

void main() {
  late RecentGatewayFake client;
  late RecentConversationController controller;
  setUp(() {
    client = RecentGatewayFake();
    controller = RecentConversationController(providerId: 'test');
  });
  tearDown(() async { controller.dispose(); await client.close(); });

  test('uses only Host membership/order and deduplicates full routed identity', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['z', 'a'], nextCursor: 'next'));
    await pumpEventQueue();
    final tail = controller.loadMore();
    client.requests.last.$2.complete(RecentConversationPage(
      conversations: [recentItem('a'), recentItem('b'), ConversationSummary(
        id: 'a', providerId: 'test', title: 'other route', status: ConversationStatus.idle,
        permissionLevel: PermissionLevel.readOnly, createdAt: DateTime.utc(2020),
        updatedAt: DateTime.utc(2020),
        resource: const RoutedResourceId(providerId: 'other', nativeResourceId: 'a'),
      )], revision: 'r1', snapshotCursor: 'e0',
    ));
    await tail;
    expect(controller.conversations.map((item) => item.title), ['z', 'a', 'b', 'other route']);
    expect(client.listFilters, isEmpty);
    expect(controller.canLoadMore, isFalse);
  });

  test('allows one tail and rejects its result after invalidation', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['old'], nextCursor: 'old-next'));
    await pumpEventQueue();
    final oldTail = controller.loadMore();
    await controller.loadMore();
    expect(client.requests.length, 2);
    client.change('r2');
    expect(client.requests.last.$1, isNull);
    client.requests.last.$2.complete(recentPage(['new'], revision: 'r2', snapshotCursor: 'e1'));
    await pumpEventQueue();
    client.requests[1].$2.complete(recentPage(['stale']));
    await oldTail;
    expect(controller.conversations.single.id, 'new');
    expect(controller.revision, 'r2');
  });

  test('snapshot fence rejects a response invalidated during initial request', () async {
    controller.attach(client, recentProvider);
    client.change('r2');
    client.requests.first.$2.complete(recentPage(['stale']));
    await pumpEventQueue();
    expect(controller.conversations, isEmpty);
    expect(client.requests, hasLength(2));
    client.requests.last.$2.complete(recentPage(['new'], revision: 'r2', snapshotCursor: 'e1'));
    await pumpEventQueue();
    expect(controller.conversations.single.id, 'new');
  });

  test('refresh atomically restores depth and follows an anchor into later pages', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['a', 'anchor']));
    await pumpEventQueue();
    controller.anchorIdentity = 'test\u0000anchor';
    client.change('r2');
    client.requests.last.$2.complete(recentPage(['x', 'y'], revision: 'r2', nextCursor: 'new-next', snapshotCursor: 'e1'));
    await pumpEventQueue();
    expect(controller.conversations.map((item) => item.id), ['a', 'anchor']);
    expect(client.requests.last.$1, 'new-next');
    client.requests.last.$2.complete(recentPage(['anchor'], revision: 'r2', snapshotCursor: 'e1'));
    await pumpEventQueue();
    expect(controller.conversations.map((item) => item.id), ['x', 'y', 'anchor']);
  });

  test('reconnect discards cursor and rejects former runtime pages', () async {
    controller.attach(client, recentProvider);
    final old = client.requests.single.$2;
    controller.detach();
    controller.attach(client, recentProvider);
    old.complete(recentPage(['stale'], nextCursor: 'stale-next'));
    client.requests.last.$2.complete(recentPage(['fresh']));
    await pumpEventQueue();
    expect(client.requests.map((request) => request.$1), [null, null]);
    expect(controller.conversations.single.id, 'fresh');
  });

  test('cursor expiry restarts first page once; refresh errors require retry', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['old'], nextCursor: 'expired'));
    await pumpEventQueue();
    final tail = controller.loadMore();
    client.requests.last.$2.completeError(const GatewayProtocolException(
      code: 'recent_cursor_expired', message: 'expired', retryable: false,
    ));
    await pumpEventQueue();
    expect(client.requests.last.$1, isNull);
    client.requests.last.$2.completeError(StateError('index unavailable'));
    await tail;
    expect(controller.canAutoLoadMore, isFalse);
    expect(controller.error, isNotNull);
    expect(client.requests, hasLength(3));
  });

  test('tail failure is retained without automatic retry and is explicitly retryable', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['a'], nextCursor: 'next'));
    await pumpEventQueue();
    final tail = controller.loadMore();
    client.requests.last.$2.completeError(StateError('network'));
    await tail;
    expect(controller.canAutoLoadMore, isFalse);
    final retry = controller.retry();
    expect(client.requests.last.$1, 'next');
    client.requests.last.$2.complete(recentPage(['b']));
    await retry;
    expect(controller.error, isNull);
    expect(controller.conversations.map((item) => item.id), ['a', 'b']);
  });

  test('missing capability never queries ordinary caches as recent', () {
    controller.attach(client, const GatewayProvider(
      id: 'test', displayName: 'Old', status: ProviderStatus.ready,
      capabilities: GatewayCapabilities(revision: 'old', methods: ['conversation.list']),
    ));
    expect(controller.supported, isFalse);
    expect(controller.loaded, isFalse);
    expect(client.requests, isEmpty);
    expect(client.listFilters, isEmpty);
  });

  test('a Provider generation change rejects an old tail while retaining display until replacement', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['old'], nextCursor: 'tail'));
    await pumpEventQueue();
    final tail = controller.loadMore();
    controller.attach(client, const GatewayProvider(
      id: 'test', displayName: 'Test', status: ProviderStatus.ready, generation: 2,
      capabilities: GatewayCapabilities(revision: 'capability-2', methods: ['conversation.recent']),
    ));
    client.requests[1].$2.complete(recentPage(['stale']));
    await tail;
    expect(controller.conversations.single.id, 'old');
    client.requests.last.$2.complete(recentPage(['new'], revision: 'generation-2'));
    await pumpEventQueue();
    expect(controller.conversations.single.id, 'new');
  });

  test('a repeated invalid cursor error is visible without automatic retries', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['first'], nextCursor: 'bad'));
    await pumpEventQueue();
    final tail = controller.loadMore();
    client.requests.last.$2.completeError(const GatewayProtocolException(
      code: 'invalid_cursor', message: 'bad cursor', retryable: false,
    ));
    await tail;
    await pumpEventQueue();
    expect(client.requests, hasLength(2));
    expect(controller.canAutoLoadMore, isFalse);
    expect(controller.conversations.single.id, 'first');
  });

  test('100 plus ordered attention rows remain paged without client truncation', () async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(
      List.generate(20, (i) => 'active-$i'), nextCursor: '20',
    ));
    await pumpEventQueue();
    for (var offset = 20; offset < 120; offset += 20) {
      final tail = controller.loadMore();
      client.requests.last.$2.complete(recentPage(
        List.generate(20, (i) => 'active-${offset + i}'),
        nextCursor: offset == 100 ? null : '${offset + 20}',
      ));
      await tail;
    }
    expect(controller.conversations.length, 120);
    expect(controller.conversations.last.id, 'active-119');
  });
}
