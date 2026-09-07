import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recent_gateway.dart';

void main() {
  test('recent and old standalone history have independent membership and cursors', () async {
    final client = RecentGatewayFake();
    final session = DeviceSession(
      device: const PairedDevice(deviceId: 'test', displayName: 'Test', connectionKind: DeviceConnectionKind.demo),
      clientFactory: () => client,
    );
    addTearDown(session.dispose);
    await session.connect();
    client.requests.single.$2.complete(recentPage(['host-only'], nextCursor: 'recent-next'));
    await pumpEventQueue();
    expect(session.selectedProviderStandaloneConversations.single.id, 'old-chat');
    expect(session.selectedProviderRecentConversations.single.id, 'host-only');
    expect(client.listFilters.single, isA<StandaloneConversationFilter>());
    expect(session.canLoadMoreSelectedProviderConversations, isTrue);
    final recentTail = session.selectedProviderRecent!.loadMore();
    client.requests.last.$2.complete(recentPage(['host-tail']));
    await recentTail;
    expect(session.canLoadMoreSelectedProviderConversations, isTrue);
    expect(client.listFilters, hasLength(1));
    await session.loadMoreSelectedProviderConversations();
    expect(client.listFilters.last, isA<StandaloneConversationFilter>());
    expect(session.canLoadMoreSelectedProviderConversations, isFalse);
    expect(session.selectedProviderRecentConversations.map((item) => item.id), ['host-only', 'host-tail']);
  });

  test('recent invalidation does not reload or reset the standalone window', () async {
    final client = RecentGatewayFake();
    final session = DeviceSession(
      device: const PairedDevice(deviceId: 'test', displayName: 'Test', connectionKind: DeviceConnectionKind.demo),
      clientFactory: () => client,
    );
    addTearDown(session.dispose);
    await session.connect();
    client.requests.single.$2.complete(recentPage(['first']));
    await pumpEventQueue();
    await session.loadMoreSelectedProviderConversations();
    final ordinary = session.conversations;
    client.change('r2');
    client.requests.last.$2.complete(recentPage(['newly-active-old'], revision: 'r2', snapshotCursor: 'e1'));
    await pumpEventQueue();
    expect(identical(session.conversations, ordinary), isTrue);
    expect(client.listFilters, hasLength(2));
    expect(session.canLoadMoreSelectedProviderConversations, isFalse);
    expect(session.selectedProviderRecentConversations.single.id, 'newly-active-old');
  });
}
