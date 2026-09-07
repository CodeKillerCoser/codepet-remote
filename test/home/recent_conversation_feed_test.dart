import 'package:codepet_remote/application/conversations/recent_conversation_controller.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/features/home/recent_conversation_feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/recent_gateway.dart';

void main() {
  late RecentGatewayFake client;
  late RecentConversationController controller;
  late ScrollController scroll;
  setUp(() {
    client = RecentGatewayFake();
    controller = RecentConversationController(providerId: 'test');
    scroll = ScrollController();
  });
  tearDown(() async { controller.dispose(); scroll.dispose(); await client.close(); });

  Widget home({bool online = true}) => MaterialApp(home: Scaffold(
    body: ListView(controller: scroll, children: [
      const SizedBox(height: 100),
      RecentConversationFeed(
        controller: controller, scrollController: scroll, online: online, onTap: (_) {},
      ),
    ]),
  ));

  testWidgets('fills a short first viewport and has no load-more button', (tester) async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['first'], nextCursor: 'next'));
    await tester.pumpWidget(home());
    await tester.pump();
    expect(client.requests.map((request) => request.$1), [null, 'next']);
    expect(find.text('显示更多对话'), findsNothing);
    expect(find.text('加载更多'), findsNothing);
    client.requests.last.$2.complete(recentPage(['second']));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scrolling to the tail loads once and an error stops automatic retries', (tester) async {
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(
      List.generate(25, (i) => 'row-$i'), nextCursor: 'next',
    ));
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(client.requests.length, 1);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await tester.pump();
    await tester.pump();
    expect(client.requests.length, 2);
    client.requests.last.$2.completeError(StateError('offline page'));
    await tester.pumpAndSettle();
    expect(find.textContaining('offline page'), findsOneWidget);
    expect(client.requests.length, 2);
    await tester.ensureVisible(find.byKey(const Key('retry-recent')));
    await tester.tap(find.byKey(const Key('retry-recent')));
    await tester.pump();
    expect(client.requests.length, 3);
    expect(client.requests.last.$1, 'next');
    client.requests.last.$2.complete(recentPage(['recovered']));
    await tester.pumpAndSettle();
    expect(find.text('recovered'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('refresh preserves visible identity and pixel offset after insertion', (tester) async {
    final rows = List.generate(30, (i) => 'row-$i');
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(rows));
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    scroll.jumpTo(800);
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('row-10')).dy;
    client.change('r2');
    client.requests.last.$2.complete(recentPage(
      ['inserted-a', 'inserted-b', ...rows], revision: 'r2', snapshotCursor: 'e1',
    ));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('row-10')).dy, closeTo(before, 1));
    expect(scroll.offset, greaterThan(800));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('successful first pages do not cause an endless expired-tail loop', (tester) async {
    const expired = GatewayProtocolException(
      code: 'recent_cursor_expired', message: 'expired tail', retryable: false,
    );
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(['first'], nextCursor: 'tail-1'));
    await tester.pumpWidget(home());
    await tester.pump();
    expect(client.requests, hasLength(2));
    client.requests.last.$2.completeError(expired);
    await tester.pump();
    expect(client.requests, hasLength(3));
    client.requests.last.$2.complete(recentPage(['first'], revision: 'r2', nextCursor: 'tail-2'));
    await tester.pump();
    await tester.pump();
    expect(client.requests, hasLength(4));
    client.requests.last.$2.completeError(expired);
    await tester.pumpAndSettle();
    expect(find.text('expired tail'), findsOneWidget);
    expect(client.requests, hasLength(4));
    // An unrelated invalidation may update the first page, but cannot unlock
    // the exhausted automatic recovery cycle.
    client.change('r3');
    client.requests.last.$2.complete(recentPage(['first'], revision: 'r3',
      snapshotCursor: 'e1', nextCursor: 'tail-3'));
    await tester.pumpAndSettle();
    expect(client.requests, hasLength(5));
    expect(controller.canAutoLoadMore, isFalse);
    await tester.ensureVisible(find.byKey(const Key('retry-recent')));
    await tester.tap(find.byKey(const Key('retry-recent')));
    await tester.pump();
    expect(client.requests, hasLength(6));
    client.requests.last.$2.complete(recentPage(['recovered'], revision: 'r3', snapshotCursor: 'e1'));
    await tester.pumpAndSettle();
    expect(find.text('expired tail'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reconnect restores an anchor after the offline layout collapses', (tester) async {
    final rows = List.generate(30, (i) => 'row-$i');
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(rows));
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    scroll.jumpTo(800);
    await tester.pumpAndSettle();
    final before = tester.getTopLeft(find.text('row-10')).dy;
    controller.detach();
    await tester.pumpWidget(home(online: false));
    controller.attach(client, recentProvider);
    client.requests.last.$2.complete(recentPage(['inserted', ...rows]));
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('row-10')).dy, closeTo(before, 1));
    expect(client.requests.last.$1, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('deleting the top anchor preserves the next surviving row offset', (tester) async {
    final rows = List.generate(30, (i) => 'row-$i');
    controller.attach(client, recentProvider);
    client.requests.single.$2.complete(recentPage(rows));
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    scroll.jumpTo(800);
    await tester.pumpAndSettle();
    client.change('r2');
    final removed = controller.anchorCandidates.first.split('\u0000').last;
    final neighbor = rows[rows.indexOf(removed) + 1];
    final before = tester.getTopLeft(find.text(neighbor)).dy;
    final replacement = ['inserted', ...rows.where((row) => row != removed)];
    client.requests.last.$2.complete(recentPage(replacement.take(15).toList(),
      revision: 'r2', snapshotCursor: 'e1', nextCursor: 'restore-depth'));
    await tester.pump();
    expect(client.requests.last.$1, 'restore-depth');
    client.requests.last.$2.complete(recentPage(replacement.skip(15).toList(),
      revision: 'r2', snapshotCursor: 'e1', nextCursor: 'large-remaining-feed'));
    await tester.pumpAndSettle();
    expect(client.requests, hasLength(3));
    expect(controller.canLoadMore, isTrue);
    expect(find.text(removed), findsNothing);
    expect(tester.getTopLeft(find.text(neighbor)).dy, closeTo(before, 1));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('unsupported is explicit and has no cache-derived recent rows', (tester) async {
    await tester.pumpWidget(home());
    await tester.pumpAndSettle();
    expect(find.text('当前 Gateway / Provider 不支持最近会话'), findsOneWidget);
    expect(client.requests, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
