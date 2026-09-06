import 'dart:async';

import 'package:codepet_remote/application/conversations/conversation_detail_controller.dart';
import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/features/conversations/conversation_detail_screen.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/sync/gateway_event_window.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

void main() {
  test('manual history paging preserves concurrent output, retries and rejects cursor loops', () async {
    final client = _DetailClient(onGet: (conversation) async => ConversationSnapshot(
      detail: ConversationDetail(summary: conversation, committedMessages: [
        _history('recent', MessageRole.user, 'message', 'recent'),
      ]), snapshotCursor: 'H', nextCursor: 'older'));
    final session = DeviceSession(device: const PairedDevice(deviceId: 'host', displayName: 'Host',
      connectionKind: DeviceConnectionKind.demo), clientFactory: () => client, autoReconnect: false);
    await session.connect();
    addTearDown(session.dispose);
    final controller = ConversationDetailController(session: session, conversation: _idleConversation());
    addTearDown(controller.dispose);
    await controller.reload();
    expect(client.pageCalls, isEmpty);
    final pending = Completer<ConversationSnapshot>();
    client.onPage = (_) => pending.future;
    final pageLoad = controller.loadEarlier();
    await controller.loadEarlier();
    expect(client.pageCalls, ['older']);
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'while-paging', providerId: 'provider',
      conversationId: 'conversation', turnId: 'live-turn', itemId: 'live', contentId: 'live:text', kind: 'text', delta: 'live'));
    pending.complete(ConversationSnapshot(detail: ConversationDetail(summary: _idleConversation(), committedMessages: [
      _history('old', MessageRole.user, 'message', 'old'),
      _history('recent', MessageRole.user, 'message', 'stale duplicate'),
    ]), snapshotCursor: 'unrelated-page-fence', nextCursor: 'oldest'));
    await pageLoad;
    expect(controller.detail!.messages.map((m) => m.content), ['old', 'recent', 'live']);
    expect(controller.detail!.lastEventCursor, 'while-paging');
    client.onPage = (_) => Future.error(StateError('temporary failure'));
    await controller.loadEarlier();
    expect(controller.historyError, contains('temporary failure'));
    expect(controller.hasEarlier, isTrue);
    client.onPage = (_) async => ConversationSnapshot(detail: ConversationDetail(summary: _idleConversation()),
      snapshotCursor: 'H', nextCursor: 'older');
    await controller.loadEarlier();
    expect(controller.historyError, contains('repeated page cursor'));
    client.onPage = (_) async => ConversationSnapshot(detail: ConversationDetail(summary: _idleConversation()), snapshotCursor: 'H');
    await controller.loadEarlier();
    expect(client.pageCalls, ['older', 'oldest', 'oldest', 'oldest']);
    expect(controller.hasEarlier, isFalse);
    expect(controller.historyError, isNull);
  });

  testWidgets('reopening cached history includes output received off screen without another get', (tester) async {
    final client = _DetailClient();
    final session = await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'offscreen', providerId: 'provider',
      conversationId: 'conversation', turnId: 'live-turn', itemId: 'live', contentId: 'live:text', kind: 'text', delta: 'offscreen answer'));
    client.emit(TurnUpsertedEvent(eventCursor: 'offscreen-completed', turn: TurnTask(
      id: 'live-turn', providerId: 'provider', conversationId: 'conversation', status: TurnStatus.completed, updatedAt: DateTime(2026))));
    await tester.pumpWidget(MaterialApp(home: ConversationDetailScreen(session: session, conversation: _idleConversation())));
    await tester.pumpAndSettle();
    expect(find.text('offscreen answer'), findsOneWidget);
    expect(client.getCalls, 1);
    expect(client.acquireCalls, 2);
    await tester.pumpWidget(const SizedBox());
    session.messageCache.clear();
    await tester.pumpWidget(MaterialApp(home: ConversationDetailScreen(session: session, conversation: _idleConversation())));
    await tester.pumpAndSettle();
    expect(client.getCalls, 2);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('manual older page prepends without moving the visible anchor', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _DetailClient(onGet: (conversation) async => ConversationSnapshot(
      detail: ConversationDetail(summary: conversation, committedMessages: [
        for (var i = 0; i < 12; i++) _history('recent-$i', MessageRole.user, 'message', 'recent $i'),
      ]), snapshotCursor: 'H', nextCursor: 'older'));
    client.onPage = (_) async => ConversationSnapshot(detail: ConversationDetail(summary: _idleConversation(), committedMessages: [
      for (var i = 0; i < 10; i++) _history('old-$i', MessageRole.user, 'message', 'old $i'),
    ]), snapshotCursor: 'H');
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    expect(client.pageCalls, isEmpty);
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
    scroll.jumpTo(scroll.minScrollExtent);
    await tester.pumpAndSettle();
    final anchor = tester.getTopLeft(find.byKey(const Key('message-recent-0')));
    await tester.tap(find.byKey(const Key('show-earlier-messages')));
    await tester.pumpAndSettle();
    expect(client.pageCalls, ['older']);
    expect(tester.getTopLeft(find.byKey(const Key('message-recent-0'))).dy, closeTo(anchor.dy, 1));
    scroll.jumpTo(scroll.minScrollExtent);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-old-0')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('shows Provider icon and keeps conversation details collapsed',
      (tester) async {
    tester.view.physicalSize = const Size(360, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _DetailClient();
    final conversation = ConversationSummary(
      id: _conversation.id,
      providerId: _conversation.providerId,
      title: _conversation.title,
      preview: '默认隐藏的会话摘要',
      status: ConversationStatus.idle,
      permissionLevel: PermissionLevel.workspaceWrite,
      model: 'test-model',
      reasoningEffort: 'high',
      workspaceRoot: '/Users/wangxin/Documents/Codex/2026-09-05/very-long-workspace-directory/project',
      createdAt: _conversation.createdAt,
      updatedAt: _conversation.updatedAt,
      resource: _conversation.resource,
    );

    await _pumpDetail(tester, client, conversation: conversation);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conversation-provider-icon')), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('conversation-device-context')))
          .data,
      'Test · TestOS 1',
    );
    final appBar = tester.widget<AppBar>(find.byType(AppBar));
    expect(appBar.leadingWidth, 48);
    expect(appBar.titleSpacing, 0);
    expect(appBar.toolbarHeight, 64);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byKey(const Key('conversation-title-status')),
      ),
      findsOneWidget,
    );
    expect(find.text('空闲'), findsOneWidget);
    expect(find.byKey(const Key('conversation-metadata-toggle')), findsNothing);
    expect(find.byKey(const Key('conversation-title-metadata')), findsNothing);
    expect(
      tester
          .widget<AnimatedSwitcher>(
            find.byKey(const Key('conversation-title-metadata-animation')),
          )
          .duration,
      const Duration(milliseconds: 220),
    );
    expect(
      tester
          .widget<AnimatedRotation>(
            find.byKey(const Key('conversation-title-metadata-arrow')),
          )
          .duration,
      const Duration(milliseconds: 200),
    );
    expect(find.text('默认隐藏的会话摘要'), findsNothing);
    expect(find.text('test-model · high'), findsNothing);
    expect(find.text('/Users/wangxin/Documents/Codex/2026-09-05/very-long-workspace-directory/project'), findsNothing);

    await tester.tap(
      find.byKey(const Key('conversation-title-metadata-toggle')),
    );
    await tester.pump();

    expect(find.byKey(const Key('conversation-title-metadata')), findsOneWidget);
    expect(find.text('权限 · workspace-write'), findsOneWidget);
    expect(find.text('默认隐藏的会话摘要'), findsOneWidget);
    expect(find.text('test-model · high'), findsOneWidget);
    expect(find.text('/Users/wangxin/Documents/Codex/2026-09-05/very-long-workspace-directory/project'), findsOneWidget);
    await tester.pumpAndSettle();
    final path = tester.widget<SelectableText>(find.byWidgetPredicate(
      (widget) => widget is SelectableText && widget.data == conversation.workspaceRoot));
    expect(path.maxLines, isNull);
    expect(tester.getSize(find.text(conversation.workspaceRoot!)).height, greaterThan(24));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('shows the latest history page and reveals earlier messages', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        for (var index = 0; index < 45; index++)
          _history(
            'history-$index',
            MessageRole.user,
            'message',
            '历史消息 $index',
            createdMilliseconds: index,
          ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-history-0')), findsNothing);
    expect(find.byKey(const Key('message-history-44')), findsOneWidget);

    final position = _detailScrollPosition(tester);
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    expect(find.byKey(const Key('show-earlier-messages')), findsOneWidget);
    await tester.tap(find.byKey(const Key('show-earlier-messages')));
    await tester.pump();
    await tester.pump();

    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    expect(find.byKey(const Key('show-earlier-messages')), findsNothing);
    expect(find.byKey(const Key('message-history-0')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('message-history-0'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('message-history-1'))).dy,
      ),
    );

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('keeps visible messages fixed when revealing earlier messages',
      (tester) async {
    final client = _DetailClient(
      committedMessages: [
        for (var index = 0; index < 100; index++)
          _history(
            'anchored-$index',
            index.isEven ? MessageRole.user : MessageRole.assistant,
            'message',
            index < 60
                ? '较长的更早消息 $index ${List.filled(24, '内容 ').join()}'
                : '当前可见消息 $index',
            createdMilliseconds: index,
          ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    final position = _detailScrollPosition(tester);
    position.jumpTo(position.minScrollExtent);
    await tester.pumpAndSettle();
    final anchor = find.byKey(const Key('message-anchored-60'));
    final anchorTopBefore = tester.getTopLeft(anchor).dy;

    await tester.tap(find.byKey(const Key('show-earlier-messages')));
    await tester.pumpAndSettle();

    expect(anchor, findsOneWidget);
    expect(tester.getTopLeft(anchor).dy, closeTo(anchorTopBefore, 1));

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('keeps committed history in source order', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history(
          'source-first',
          MessageRole.user,
          'message',
          '输入中的第一条',
          createdMilliseconds: 2000,
        ),
        _history(
          'source-second',
          MessageRole.assistant,
          'message',
          '输入中的第二条',
          createdMilliseconds: 1000,
        ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const Key('message-source-first'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('message-source-second'))).dy,
      ),
    );

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('renders history directly without a collapsible section', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history('one', MessageRole.user, 'message', '第一条'),
        _history('two', MessageRole.assistant, 'message', '第二条'),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    final firstMessageTop = tester
        .getTopLeft(find.byKey(const Key('message-one')))
        .dy;
    expect(find.byKey(const Key('messages-section-toggle')), findsNothing);
    expect(find.text('消息与事件'), findsNothing);
    expect(find.byKey(const Key('message-one')), findsOneWidget);
    expect(find.byKey(const Key('message-two')), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('conversation-title-metadata-toggle')),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byKey(const Key('message-one'))).dy,
      firstMessageTop,
    );

    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'direct-live',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'direct-turn',
      itemId: 'direct-item',
      contentId: 'direct-item:text',
      kind: 'text',
      delta: '直接显示的新消息',
    ));
    await tester.pump();
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('直接显示的新消息'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('coalesces live output within a frame without dropping deltas',
      (tester) async {
    final client = _DetailClient();
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    for (var index = 0; index < 20; index++) {
      client.emit(TurnOutputDeltaEvent(
        eventCursor: 'burst-$index',
        providerId: 'provider',
        conversationId: 'conversation',
        turnId: 'burst-turn',
        itemId: 'burst-item',
        contentId: 'burst-item:text',
        kind: 'text',
        delta: '$index ',
      ));
    }
    await tester.pump();
    await tester.pump();

    final liveMarkdown = tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .map((body) => body.data)
        .where((data) => data.startsWith('0 1 2 '));
    expect(liveMarkdown,
        contains('0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 '));
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('shows a scroll-to-bottom button and scrolls on tap', (tester) async {
    final client = _DetailClient(
      committedMessages: _longHistory(),
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    final position = _detailScrollPosition(tester);
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scroll-to-bottom')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scroll-to-bottom')));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(find.byKey(const Key('scroll-to-bottom')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('follows live output near bottom but preserves far scroll position', (tester) async {
    final client = _DetailClient(
      committedMessages: _longHistory(),
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    final position = _detailScrollPosition(tester);
    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'near-live',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'near-turn',
      itemId: 'near-item',
      contentId: 'near-item:text',
      kind: 'text',
      delta: '近底部实时消息',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(find.text('近底部实时消息'), findsOneWidget);

    position.jumpTo(0);
    await tester.pump();
    final farOffset = position.pixels;
    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'far-live',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'far-turn',
      itemId: 'far-item',
      contentId: 'far-item:text',
      kind: 'text',
      delta: '远离底部实时消息',
    ));
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(farOffset, 1));
    expect(position.extentAfter, greaterThan(160));

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('stream updates do not interrupt a drag near the bottom', (tester) async {
    final client = _DetailClient(committedMessages: _longHistory());
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();
    final position = _detailScrollPosition(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const Key('conversation-detail'))),
    );
    await gesture.moveBy(const Offset(0, 20));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 60));
    await tester.pump();
    final offset = position.pixels;
    expect(position.extentAfter, greaterThan(0));
    expect(position.extentAfter, lessThan(160));
    for (var index = 0; index < 3; index++) {
      client.emit(TurnOutputDeltaEvent(
        eventCursor: 'drag-$index', providerId: 'provider',
        conversationId: 'conversation', turnId: 'drag-turn', itemId: 'drag-item',
        contentId: 'drag-text', kind: 'text', delta: 'more output ',
      ));
      await tester.pump();
      await tester.pump();
      expect(position.pixels, closeTo(offset, 1));
    }
    await gesture.up();
    await tester.pump(const Duration(seconds: 1));
    expect(position.pixels, lessThanOrEqualTo(offset));
    final releasedOffset = position.pixels;
    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'after-drag', providerId: 'provider',
      conversationId: 'conversation', turnId: 'drag-turn', itemId: 'drag-item',
      contentId: 'drag-text', kind: 'text', delta: 'after release',
    ));
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(releasedOffset, 1));
    expect(find.byKey(const Key('scroll-to-bottom')), findsOneWidget);
    await tester.tap(find.byKey(const Key('scroll-to-bottom')));
    for (var frame = 0; frame < 5; frame++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('terminal turn preserves live output without fetching history', (tester) async {
    final client = _DetailClient();
    await _pumpDetail(tester, client);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', itemId: 'item', contentId: 'item:text', kind: 'text', delta: 'live-only'));
    await tester.pump();
    expect(find.text('live-only'), findsOneWidget);

    client.emit(TurnUpsertedEvent(eventCursor: 'terminal', turn: TurnTask(id: 'turn', providerId: 'provider', conversationId: 'conversation', status: TurnStatus.completed, updatedAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.getCalls, 1);
    expect(find.text('live-only'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  for (final terminalStatus in [TurnStatus.completed, TurnStatus.interrupted, TurnStatus.failed]) {
    testWidgets(
        '$terminalStatus clears a stale running turn and re-enables the composer',
        (tester) async {
      final client = _DetailClient();
      final running = TurnTask(
        id: 'terminal-turn',
        providerId: 'provider',
        conversationId: 'conversation',
        status: TurnStatus.running,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true),
      );
      await _pumpDetail(
        tester,
        client,
        conversation: _idleConversation(activeTurn: running),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byKey(const Key('turn-input'))).enabled,
        isFalse,
      );

      client.emit(TurnUpsertedEvent(
        eventCursor: 'terminal-$terminalStatus',
        turn: TurnTask(
          id: running.id,
          providerId: running.providerId,
          conversationId: running.conversationId,
          status: terminalStatus,
          updatedAt: running.updatedAt,
          completedAt: running.updatedAt,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(client.getCalls, 1);
      expect(
        tester.widget<TextField>(find.byKey(const Key('turn-input'))).enabled,
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
      await client.close();
    });
  }

  testWidgets('stops the active turn and resolves a pending approval', (tester) async {
    final now = DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true);
    final turn = TurnTask(
      id: 'provider\u0000turn-active', providerId: 'provider',
      conversationId: _conversation.id, status: TurnStatus.running,
      updatedAt: now,
      resource: const RoutedResourceId(providerId: 'provider', nativeResourceId: 'turn-active'),
      conversationResource: _conversation.resource,
    );
    final provider = GatewayProvider(
      id: _detailProviderId, displayName: 'Provider', status: ProviderStatus.ready,
      capabilities: const GatewayCapabilities(
        revision: 'revision-1',
        methods: ['conversation.get', 'turn.send', 'turn.interrupt', 'approval.resolve'],
        turnSend: TurnSendCapabilities(),
      ),
    );
    final approval = GatewayMessage(
      id: 'provider\u0000approval-1', itemId: 'approval-1',
      turnId: turn.id, role: MessageRole.system, kind: 'approval',
      content: '允许执行测试命令吗？', title: '执行命令',
      approvalDescription: '允许执行测试命令吗？', approvalStatus: 'pending',
      status: 'pending',
      approvalDecisions: const [ApprovalDecision.approve, ApprovalDecision.deny],
      resource: const RoutedResourceId(providerId: 'provider', nativeResourceId: 'approval-1'),
      createdAt: now, isStreaming: false,
    );
    final client = _DetailClient(provider: provider, committedMessages: [approval]);
    await _pumpDetail(tester, client, conversation: _idleConversation(activeTurn: turn));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('turn-interrupt')), findsOneWidget);
    expect(find.byKey(const Key('pending-approval-title')), findsOneWidget);
    await tester.tap(find.byKey(const Key('approval-approve')));
    await tester.pumpAndSettle();
    expect(client.approvalCalls, [ApprovalDecision.approve]);
    expect(find.text('已批准'), findsOneWidget);
    await tester.tap(find.byKey(const Key('turn-interrupt')));
    await tester.pumpAndSettle();
    expect(client.interruptCalls, [turn.id]);
    expect(find.byKey(const Key('turn-send')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('event stream failure preserves rendered detail and live output', (tester) async {
    final client = _DetailClient();
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', itemId: 'item', contentId: 'item:text', kind: 'text', delta: 'stale-live'));
    await tester.pump();
    client.eventsController.addError(StateError('socket lost'));
    await tester.pump();
    await tester.pump();
    expect(find.text('stale-live'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('collapses process, copies only final output and moves file changes above input', (tester) async {
    final client = _DetailClient(committedMessages: [
      _history('user', MessageRole.user, 'message', 'request'),
      _history('reason', MessageRole.assistant, 'reasoning', 'completed'),
      _history('commentary', MessageRole.assistant, 'message', 'progress note'),
      _history('tool', MessageRole.system, 'command', 'pwd', status: 'completed'),
      _history('files', MessageRole.system, 'file-change', '2 file change(s)'),
      _history('final', MessageRole.assistant, 'message', 'final output'),
    ]);
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    expect(find.text('progress note'), findsNothing);
    expect(find.text('completed'), findsNothing);
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(find.text('文件变更 · 2 次'), findsOneWidget);
    expect(tester.getBottomLeft(find.text('文件变更 · 2 次')).dy,
      lessThan(tester.getTopLeft(find.byKey(const Key('turn-input'))).dy));
    await tester.tap(find.text('执行过程'));
    await tester.pumpAndSettle();
    expect(find.text('progress note'), findsOneWidget);
    expect(find.byTooltip('复制'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('renders committed messages, tool activity and approval status', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history('user', MessageRole.user, 'message', 'Show the history.'),
        _history('assistant', MessageRole.assistant, 'message', 'History is ready.'),
        _history(
          'command',
          MessageRole.system,
          'command',
          'git status --short',
          title: 'Run git status --short',
          status: 'completed',
        ),
        _history(
          'approval',
          MessageRole.system,
          'approval',
          'Run git status --short',
          title: 'Approve command',
          status: 'approved',
          approvalStatus: 'approved',
        ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(find.text('Show the history.'), findsOneWidget);
    expect(find.text('History is ready.'), findsOneWidget);
    expect(find.text('Run git status --short'), findsWidgets);
    expect(find.text('Approve command'), findsOneWidget);
    expect(find.text('已批准'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('opens command details in a sheet without expanding the timeline',
      (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history(
          'running-command',
          MessageRole.system,
          'command',
          'find lib -type f',
          title: '命令执行',
          status: 'running',
          tool: GatewayToolInvocation(
            callId: 'running-command',
            name: 'shell',
            category: 'command',
            originKind: 'builtin',
            originName: 'codex',
            input: const GatewayCommandToolInput(
              command: 'find lib -type f',
              cwd: '/workspace',
              truncation: GatewayContentTruncation(
                originalBytes: 8192,
                retainedBytes: 16,
                strategy: 'tail',
              ),
            ),
            outcome: const GatewayToolSuccess(
              content: [
              GatewayMessageContent(
                id: 'running-command:output',
                kind: 'output',
                text: 'lib/main.dart',
                truncation: GatewayContentTruncation(
                  originalBytes: 4096,
                  retainedBytes: 13,
                  strategy: 'head-tail',
                ),
              ),
              ],
              exitCode: 0,
            ),
            durationMs: 18,
          ),
        ),
      ],
    );
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final command = find.byKey(
      const Key('timeline-command-running-command'),
    );
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('运行中'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(of: command, matching: find.byType(AnimatedCrossFade)),
      findsNothing,
    );
    expect(find.text('find lib -type f'), findsOneWidget);
    final commandText = tester.widget<Text>(find.text('find lib -type f'));
    expect(commandText.maxLines, 1);
    expect(commandText.overflow, TextOverflow.ellipsis);
    final timelineHeight = tester.getSize(command).height;

    await tester.tap(
      find.descendant(of: command, matching: find.text('shell')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byKey(const Key('tool-detail-sheet')), findsOneWidget);
    expect(find.byKey(const Key('tool-detail-command')), findsOneWidget);
    expect(find.text('工具详情'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('tool-detail-sheet')),
      matching: find.textContaining('find lib -type f')), findsOneWidget);
    expect(find.textContaining('调用：shell'), findsOneWidget);
    expect(find.textContaining('目录：/workspace'), findsOneWidget);
    expect(find.textContaining('lib/main.dart'), findsOneWidget);
    expect(find.textContaining('originalBytes=8192'), findsOneWidget);
    expect(find.textContaining('retainedBytes=16'), findsOneWidget);
    expect(find.textContaining('strategy=tail'), findsOneWidget);
    expect(find.textContaining('originalBytes=4096'), findsOneWidget);
    expect(find.textContaining('retainedBytes=13'), findsOneWidget);
    expect(find.textContaining('strategy=head-tail'), findsOneWidget);
    expect(
      find.descendant(of: command, matching: find.byType(AnimatedCrossFade)),
      findsNothing,
    );
    expect(tester.getSize(command).height, timelineHeight);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('renders conversational text as Markdown', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history('user-markdown', MessageRole.user, 'message', '**user bold**'),
        _history(
          'assistant-markdown',
          MessageRole.assistant,
          'message',
          '**assistant bold**',
        ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    final markdownBodies = tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .map((body) => body.data)
        .toList(growable: false);
    expect(markdownBodies, containsAll(['**user bold**', '**assistant bold**']));
    final assistantBodyBefore = tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .singleWhere((body) => body.data == '**assistant bold**');
    await tester.tap(
      find.byKey(const Key('conversation-title-metadata-toggle')),
    );
    await tester.pump();
    final assistantBodyAfter = tester
        .widgetList<MarkdownBody>(find.byType(MarkdownBody))
        .singleWhere((body) => body.data == '**assistant bold**');
    expect(identical(assistantBodyBefore, assistantBodyAfter), isTrue);
    expect(find.text('**assistant bold**', findRichText: true), findsNothing);
    expect(find.text('assistant bold', findRichText: true), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('does not duplicate a committed body when its delta replays after the snapshot', (tester) async {
    final committed = GatewayMessage(
      id: 'item',
      itemId: 'item',
      turnId: 'turn',
      role: MessageRole.assistant,
      kind: 'message',
      content: 'committed body',
      contentIds: const ['item:text'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      isStreaming: false,
    );
    final client = _DetailClient(
      committedMessages: [committed],
      eventDuringFirstGet: const TurnOutputDeltaEvent(
        eventCursor: 'after-snapshot',
        providerId: 'provider',
        conversationId: 'conversation',
        turnId: 'turn',
        itemId: 'item',
        contentId: 'item:text',
        kind: 'text',
        delta: 'committed body',
      ),
    );

    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(find.text('committed body'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('lays out composer toolbar and sends Provider defaults with original text', (tester) async {
    final provider = _providerWith(
      revision: 'revision-layout',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [
            ProviderChoice(id: 'read', displayName: 'Read only'),
            ProviderChoice(id: 'write', displayName: 'Workspace write'),
          ],
          defaultId: 'write',
        ),
        reasoningEffort: ProviderChoiceSet(
          options: [ProviderChoice(id: 'high', displayName: 'High')],
          defaultId: 'high',
        ),
        modelCatalog: FlatModelCatalog(
          models: [
            ProviderChoice(id: 'fast', displayName: 'Fast'),
            ProviderChoice(id: 'deep', displayName: 'Deep'),
          ],
          defaultSelection: FlatModelSelection(modelId: 'fast'),
        ),
      ),
    );
    final conversation = _idleConversation(
      selection: const TurnSendSelection(
        accessModeId: 'read',
        model: FlatModelSelection(modelId: 'deep'),
      ),
    );
    final client = _DetailClient(provider: provider);
    await _pumpDetail(tester, client, conversation: conversation);
    await tester.pumpAndSettle();

    final inputBottom = tester.getBottomLeft(find.byKey(const Key('turn-input'))).dy;
    final toolbarTop = tester.getTopLeft(find.byKey(const Key('composer-toolbar'))).dy;
    expect(inputBottom, lessThanOrEqualTo(toolbarTop));
    expect(
      tester.getCenter(find.byKey(const Key('access-mode-selector'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('reasoning-effort-selector'))).dx),
    );
    expect(find.text('访问 · Read only'), findsOneWidget);
    expect(find.text('推理 · High'), findsOneWidget);
    expect(find.text('模型 · Deep'), findsOneWidget);
    final reasoningPopup = tester.widget<PopupMenuButton<String>>(
      find.descendant(
        of: find.byKey(const Key('reasoning-effort-selector')),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    expect(reasoningPopup.enabled, isFalse);

    await tester.enterText(find.byKey(const Key('turn-input')), '  original text\n');
    await tester.pump();
    final sendButton = tester.widget<IconButton>(
      find.byKey(const Key('turn-send')),
    );
    expect(
      sendButton.onPressed,
      isNotNull,
      reason: tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .decoration
          ?.hintText,
    );
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();

    expect(client.sendCalls, hasLength(1));
    expect(client.sendCalls.single.text, '  original text\n');
    expect(client.sendCalls.single.capabilityRevision, 'revision-layout');
    expect(client.sendCalls.single.selection.accessModeId, 'read');
    expect(client.sendCalls.single.selection.reasoningEffortId, 'high');
    expect(client.sendCalls.single.selection.model?.toJson(), {
      'kind': 'flat',
      'modelId': 'deep',
    });
    expect(find.byKey(const Key('turn-input')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller
          ?.text,
      isEmpty,
    );
    expect(find.text('original text'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  for (final acquired in [false, true]) {
    for (final hasHistory in [false, true]) {
      testWidgets('uses resume history before get (acquired=$acquired history=$hasHistory)',
          (tester) async {
        final client = _ResumeDetailClient(onResume: (conversation) async => ConversationResumeResult(
          interaction: acquired ? const ConversationInteraction(selection: TurnSendSelection()) : null,
          interactionError: acquired ? null : const GatewayProtocolException(
            code: 'conversation_write_conflict', message: 'writer held', retryable: true,
          ),
          loadHistory: hasHistory ? () async => ConversationSnapshot(
            detail: ConversationDetail(summary: conversation), snapshotCursor: 'H',
          ) : null,
        ));
        await _pumpDetail(tester, client, conversation: _idleConversation());
        await tester.pump();
        expect(client.resumeCalls, 1);
        expect(client.acquireCalls, 0);
        expect(client.getCalls, hasHistory ? 0 : 1);
        expect(find.byKey(const Key('interaction-unavailable')),
            acquired ? findsNothing : findsOneWidget);
        expect(find.byKey(const Key('conversation-history-error')), findsNothing);
        await tester.pumpWidget(const SizedBox());
        await client.close();
      });
    }
  }

  testWidgets('resume metadata keeps the known project while updating the title', (tester) async {
    const project = RoutedResourceId(providerId: 'provider', nativeResourceId: 'project');
    final initial = ConversationSummary(
      id: 'conversation', providerId: 'provider', title: 'Before resume',
      status: ConversationStatus.idle, permissionLevel: PermissionLevel.readOnly,
      createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026), project: project,
      resource: const RoutedResourceId(providerId: 'provider', nativeResourceId: 'conversation'),
    );
    final client = _ResumeDetailClient(onResume: (_) async => ConversationResumeResult(
      interaction: const ConversationInteraction(selection: TurnSendSelection()),
      loadHistory: () async => ConversationSnapshot(
        detail: ConversationDetail(summary: _idleConversation()), snapshotCursor: 'H',
      ),
    ));
    final session = await _pumpDetail(tester, client, conversation: initial);
    await tester.pump();
    // The screen controller is tested separately to inspect metadata, while the
    // mounted screen above exercises layout under the same resume response.
    final controller = ConversationDetailController(session: session, conversation: initial);
    addTearDown(controller.dispose);
    await controller.reload();
    expect(controller.detail!.summary.project, project);
    expect(controller.detail!.summary.title, _idleConversation().title);
    client.emit(ConversationUpsertedEvent(eventCursor: 'metadata', conversation: _idleConversation()));
    await tester.pump();
    expect(controller.detail!.summary.project, project);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('buffers live output while the combined resume is in flight', (tester) async {
    final pending = Completer<ConversationResumeResult>();
    final client = _ResumeDetailClient(onResume: (_) => pending.future);
    await _pumpDetail(tester, client, conversation: _idleConversation());
    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'during-resume', providerId: 'provider', conversationId: 'conversation',
      turnId: 'resume-turn', itemId: 'resume-item', contentId: 'resume-item:text',
      kind: 'text', delta: 'resume期间的输出',
    ));
    pending.complete(ConversationResumeResult(
      interaction: const ConversationInteraction(selection: TurnSendSelection()),
      loadHistory: () async => ConversationSnapshot(
        detail: ConversationDetail(summary: _idleConversation()), snapshotCursor: 'H',
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(client.getCalls, 0);
    expect(find.text('resume期间的输出'), findsOneWidget);
    expect(find.byKey(const Key('conversation-history-error')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('loads after full capabilities arrive with the summary revision', (tester) async {
    final client = _DetailClient();
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pump();
    final previousGets = client.getCalls;
    client.provider = _providerWith(revision: 'hydrated-revision', turnSend: const TurnSendCapabilities());
    client.emit(GatewayProviderChangedEvent(
      eventCursor: 'summary-revision',
      provider: GatewayProvider(
        id: client.provider.id, displayName: client.provider.displayName,
        status: client.provider.status, capabilitiesLoaded: false,
        capabilities: const GatewayCapabilities(revision: 'hydrated-revision', methods: []),
      ),
    ));
    await tester.pump();
    await tester.pump();
    expect(client.getCalls, previousGets + 1);
    expect(find.text('当前 Provider 不支持加载会话详情。'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('enables interaction only after acquire and uses resumed selection',
      (tester) async {
    final acquired = Completer<ConversationInteraction>();
    final provider = _providerWith(
      revision: 'revision-acquire',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [
            ProviderChoice(id: 'read', displayName: 'Read only'),
            ProviderChoice(id: 'write', displayName: 'Workspace write'),
          ],
          defaultId: 'read',
        ),
        reasoningEffort: ProviderChoiceSet(
          options: [
            ProviderChoice(id: 'low', displayName: 'Low'),
            ProviderChoice(id: 'high', displayName: 'High'),
          ],
          defaultId: 'low',
        ),
        modelCatalog: FlatModelCatalog(
          models: [
            ProviderChoice(id: 'fast', displayName: 'Fast'),
            ProviderChoice(id: 'deep', displayName: 'Deep'),
          ],
          defaultSelection: FlatModelSelection(modelId: 'fast'),
        ),
      ),
    );
    final client = _DetailClient(
      provider: provider,
      onAcquire: (_) => acquired.future,
    );
    await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(
        selection: const TurnSendSelection(
          accessModeId: 'read',
          reasoningEffortId: 'low',
          model: FlatModelSelection(modelId: 'fast'),
        ),
      ),
    );
    await tester.pump();

    expect(client.acquireCalls, 1);
    expect(client.getCalls, 0);
    expect(
      tester.widget<TextField>(find.byKey(const Key('turn-input'))).enabled,
      isFalse,
    );
    expect(find.text('正在获取会话交互权'), findsOneWidget);

    acquired.complete(const ConversationInteraction(
      selection: TurnSendSelection(
        accessModeId: 'write',
        reasoningEffortId: 'high',
        model: FlatModelSelection(modelId: 'deep'),
      ),
    ));
    await tester.pump();
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byKey(const Key('turn-input'))).enabled,
      isTrue,
    );
    expect(find.text('访问 · Workspace write'), findsOneWidget);
    expect(find.text('推理 · High'), findsOneWidget);
    expect(find.text('模型 · Deep'), findsOneWidget);
    expect(client.getCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('does not fetch history after leaving during interaction acquisition',
      (tester) async {
    final acquired = Completer<ConversationInteraction>();
    final client = _DetailClient(onAcquire: (_) => acquired.future);
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pump();
    expect(client.acquireCalls, 1);
    expect(client.getCalls, 0);

    await tester.pumpWidget(const SizedBox());
    acquired.complete(const ConversationInteraction(selection: TurnSendSelection()));
    await tester.pump();
    expect(client.getCalls, 0);
    await client.close();
  });

  testWidgets('keeps sending disabled when Codex interaction is owned elsewhere',
      (tester) async {
    final client = _DetailClient(
      onAcquire: (_) => Future.error(const GatewayProtocolException(
        code: 'conversation_write_conflict',
        message: 'writer conflict',
        retryable: true,
      )),
    );
    await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(),
    );
    await tester.pump();

    expect(find.byKey(const Key('interaction-error')), findsOneWidget);
    expect(client.getCalls, 1);
    expect(
      tester.widget<Text>(find.byKey(const Key('interaction-error'))).data,
      '该会话正在被另一个客户端写入，暂时无法继续对话。',
    );
    expect(find.byKey(const Key('interaction-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('turn-input')), findsNothing);
    expect(find.byKey(const Key('composer-toolbar')), findsNothing);
    expect(find.byKey(const Key('turn-send')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('raises the composer above the software keyboard', (tester) async {
    final client = _DetailClient();
    await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    final logicalHeight =
        tester.view.physicalSize.height / tester.view.devicePixelRatio;
    final logicalKeyboardInset = 300 / tester.view.devicePixelRatio;
    final composerBottom = tester
        .getBottomLeft(find.byKey(const Key('conversation-composer')))
        .dy;
    expect(
      composerBottom,
      lessThanOrEqualTo(logicalHeight - logicalKeyboardInset),
    );

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('disables empty, unavailable, active-turn and offline sends while retaining draft', (tester) async {
    final unavailableProvider = _providerWith(
      revision: 'revision-unavailable',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [
            ProviderChoice(
              id: 'disabled',
              displayName: 'Unavailable mode',
              enabled: false,
              disabledReason: 'Disabled by Provider',
            ),
          ],
        ),
      ),
    );
    final unavailableClient = _DetailClient(provider: unavailableProvider);
    final unavailableSession = await _pumpDetail(
      tester,
      unavailableClient,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('turn-input')), 'cannot send');
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox());
    unawaited(unavailableSession.disconnect());

    final activeTurn = TurnTask(
      id: 'active',
      providerId: 'provider',
      conversationId: 'conversation',
      status: TurnStatus.running,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );
    final activeClient = _DetailClient();
    final activeSession = await _pumpDetail(
      tester,
      activeClient,
      conversation: _idleConversation(activeTurn: activeTurn),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('运行中'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    unawaited(activeSession.disconnect());

    final offlineClient = _DetailClient();
    final session = await _pumpDetail(
      tester,
      offlineClient,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'saved offline');
    await tester.pump();
    unawaited(session.disconnect());
    await tester.pump();
    expect(find.text('saved offline'), findsOneWidget);
    expect(find.text('设备连接已断开'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('uses a new request id after an explicit failure', (tester) async {
    var attempt = 0;
    final client = _DetailClient(onSend: (call) {
      attempt++;
      if (attempt == 1) {
        return Future.error(const GatewayProtocolException(
          code: 'provider_instance_unavailable',
          message: 'Provider unavailable',
          retryable: true,
        ));
      }
      return Future.value(_receipt(call));
    });
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    await tester.pump();
    await tester.pump();
    await tester.enterText(find.byKey(const Key('turn-input')), 'retry me');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    final firstId = client.sendCalls.single.clientRequestId;
    expect(find.byKey(const Key('turn-unknown-refresh')), findsNothing);
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    expect(client.sendCalls, hasLength(2));
    expect(client.sendCalls.last.clientRequestId, isNot(firstId));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('keeps summary and composer usable when history fails',
      (tester) async {
    final client = _DetailClient(
      onGet: (_) => Future.error(StateError('history unavailable')),
    );
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('conversation-detail')), findsOneWidget);
    expect(find.byKey(const Key('conversation-history-error')), findsOneWidget);
    expect(find.byKey(const Key('turn-input')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('turn-input')), 'send anyway');
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    expect(client.sendCalls.single.text, 'send anyway');

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('updates the live item from its canonical event without terminal history', (tester) async {
    final committed = <GatewayMessage>[];
    late TurnSendReceipt accepted;
    final client = _DetailClient(
      committedMessages: committed,
      onSend: (call) {
        accepted = _receipt(call);
        committed.add(accepted.inputItem!);
        return Future.value(accepted);
      },
    );
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'start flow');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    client.emit(TurnOutputDeltaEvent(
      eventCursor: 'sent-delta',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: accepted.turn.id,
      itemId: 'answer',
      contentId: 'answer:text',
      kind: 'text',
      delta: 'streaming answer',
    ));
    await tester.pump();
    expect(find.text('streaming answer'), findsOneWidget);
    committed.add(GatewayMessage(
      id: 'answer',
      itemId: 'answer',
      turnId: accepted.turn.id,
      role: MessageRole.assistant,
      kind: 'message',
      content: 'committed answer',
      contentIds: const ['answer:text'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(6000, isUtc: true),
      isStreaming: false,
    ));
    client.emit(ConversationItemUpsertedEvent(eventCursor: 'canonical-answer',
      conversationId: 'conversation', item: committed.last));
    client.emit(TurnUpsertedEvent(
      eventCursor: 'sent-terminal',
      turn: TurnTask(
        id: accepted.turn.id,
        providerId: 'provider',
        conversationId: 'conversation',
        status: TurnStatus.completed,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(6000, isUtc: true),
        completedAt: DateTime.fromMillisecondsSinceEpoch(6000, isUtc: true),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('streaming answer'), findsNothing);
    expect(find.text('committed answer'), findsOneWidget);
    expect(client.getCalls, 1);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('groups models in the menu and returns provider plus model identity', (tester) async {
    final provider = _providerWith(
      revision: 'revision-grouped',
      turnSend: const TurnSendCapabilities(
        modelCatalog: GroupedModelCatalog(
          providers: [
            ModelProviderGroup(
              id: 'provider-a',
              displayName: 'Provider A',
              models: [ProviderChoice(id: 'shared', displayName: 'Model A')],
            ),
            ModelProviderGroup(
              id: 'provider-b',
              displayName: 'Provider B',
              models: [ProviderChoice(id: 'shared', displayName: 'Model B')],
            ),
          ],
          defaultSelection: GroupedModelSelection(
            providerId: 'provider-a',
            modelId: 'shared',
          ),
        ),
      ),
    );
    final client = _DetailClient(provider: provider);
    await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Provider A'), findsOneWidget);
    expect(find.text('Provider B'), findsOneWidget);
    await tester.tap(find.text('Model B'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'grouped');
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNotNull,
      reason: tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .decoration
          ?.hintText,
    );
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();

    expect(client.sendCalls.single.selection.model?.toJson(), {
      'kind': 'grouped',
      'providerId': 'provider-b',
      'modelId': 'shared',
    });
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('requires review before a new request after a transport unknown', (tester) async {
    var attempts = 0;
    final firstPending = Completer<TurnSendReceipt>();
    final client = _DetailClient(onSend: (call) {
      attempts++;
      if (attempts == 1) return firstPending.future;
      return Future.value(_receipt(call));
    });
    final session = await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'pending');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    final pendingMessageKey = Key(
      'message-pending-user:${client.sendCalls.single.clientRequestId}',
    );
    expect(find.byKey(pendingMessageKey), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller!
          .text,
      'pending',
    );
    client.emit(TurnOutputDeltaEvent(
      eventCursor: 'pending-delta',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'turn-pending',
      itemId: 'answer-pending',
      contentId: 'answer-pending:text',
      kind: 'text',
      delta: 'answer while send is pending',
    ));
    await tester.pump();
    expect(find.byKey(pendingMessageKey), findsOneWidget);
    expect(find.text('answer while send is pending'), findsOneWidget);
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    expect(client.sendCalls, hasLength(1));
    final firstCall = client.sendCalls.single;
    expect(firstCall.providerId, _detailProviderId);
    expect(
      conversationRoutingKey(firstCall.conversation),
      conversationRoutingKey(_idleConversation()),
    );
    expect(firstCall.capabilityRevision, 'revision-1');
    expect(firstCall.text, 'pending');
    expect(firstCall.selection.toJson(), isEmpty);

    firstPending.completeError(
      const GatewayConnectionException(
        'timeout',
        retryable: true,
        outcomeUnknown: true,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('turn-send-error')), findsOneWidget);
    expect(find.textContaining('可能产生重复任务'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller!
          .text,
      'pending',
    );
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    expect(client.sendCalls, hasLength(1));
    expect(client.getCalls, 2);

    client.emit(GatewayProviderChangedEvent(
      eventCursor: 'provider-after-unknown',
      provider: _providerWith(
        revision: 'revision-after-unknown',
        turnSend: const TurnSendCapabilities(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(
      session.handshake?.providers.single.capabilities.revision,
      'revision-after-unknown',
    );
    expect(find.byKey(const Key('turn-send-error')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller!
          .text,
      'pending',
    );
    expect(client.sendCalls, hasLength(1));

    final getCallsBeforeRefresh = client.getCalls;
    await tester.tap(find.byKey(const Key('turn-unknown-refresh')));
    await tester.pumpAndSettle();
    expect(client.getCalls, getCallsBeforeRefresh + 1);
    expect(client.sendCalls, hasLength(1));

    await tester.tap(find.byKey(const Key('turn-unknown-dismiss')));
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    expect(client.sendCalls, hasLength(2));
    final secondCall = client.sendCalls.last;
    expect(secondCall.clientRequestId, isNot(firstCall.clientRequestId));
    expect(secondCall.providerId, firstCall.providerId);
    expect(
      conversationRoutingKey(secondCall.conversation),
      conversationRoutingKey(firstCall.conversation),
    );
    expect(secondCall.capabilityRevision, 'revision-after-unknown');
    expect(secondCall.text, firstCall.text);
    expect(secondCall.selection.toJson(), firstCall.selection.toJson());
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller!
          .text,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('revision change preserves draft and ignores the old send callback', (tester) async {
    final pending = Completer<TurnSendReceipt>();
    final firstProvider = _providerWith(
      revision: 'revision-old',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [ProviderChoice(id: 'old', displayName: 'Old mode')],
          defaultId: 'old',
        ),
        reasoningEffort: ProviderChoiceSet(
          options: [ProviderChoice(id: 'old', displayName: 'Old effort')],
          defaultId: 'old',
        ),
        modelCatalog: FlatModelCatalog(
          models: [ProviderChoice(id: 'old', displayName: 'Old model')],
          defaultSelection: FlatModelSelection(modelId: 'old'),
        ),
      ),
    );
    final client = _DetailClient(
      provider: firstProvider,
      onSend: (_) => pending.future,
    );
    final session = await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(
        selection: const TurnSendSelection(
          accessModeId: 'old',
          reasoningEffortId: 'old',
          model: FlatModelSelection(modelId: 'old'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'keep this draft');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();

    final nextProvider = _providerWith(
      revision: 'revision-new',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [ProviderChoice(id: 'new', displayName: 'New mode')],
          defaultId: 'new',
        ),
        reasoningEffort: ProviderChoiceSet(
          options: [ProviderChoice(id: 'new', displayName: 'New effort')],
        ),
        modelCatalog: FlatModelCatalog(
          models: [ProviderChoice(id: 'new', displayName: 'New model')],
        ),
      ),
    );
    client.emit(GatewayProviderChangedEvent(
      eventCursor: 'provider-new',
      provider: nextProvider,
    ));
    expect(
      session.handshake?.providers.single.capabilities.revision,
      'revision-new',
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final accessLabels = tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(const Key('access-mode-selector')),
          matching: find.byType(Text),
        ))
        .map((text) => text.data)
        .toList();
    expect(accessLabels, contains('访问 · New mode'));
    expect(
      find.descendant(
        of: find.byKey(const Key('reasoning-effort-selector')),
        matching: find.text('推理 · New effort'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('model-selector')),
        matching: find.text('模型 · New model'),
      ),
      findsOneWidget,
    );
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    expect(find.byKey(const Key('turn-send-error')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller!
          .text,
      'keep this draft',
    );

    pending.complete(_receipt(client.sendCalls.single));
    await tester.pump();
    expect(find.byKey(const Key('turn-send-error')), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .controller!
          .text,
      'keep this draft',
    );
    expect(client.sendCalls, hasLength(1));
    await tester.tap(find.byKey(const Key('turn-unknown-dismiss')));
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNotNull,
    );
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('ignores legacy interaction lease expiry', (tester) async {
    final client = _DetailClient(
      onAcquire: (conversation) async => ConversationInteraction(
        selection:
            conversation.turnSendSelection ?? const TurnSendSelection(),
        leaseExpiresAt:
            DateTime.now().toUtc().add(const Duration(seconds: 1)),
      ),
    );
    await _pumpDetail(tester, client);
    await tester.pump();
    expect(client.acquireCalls, 1);

    await tester.pump(const Duration(milliseconds: 750));
    await tester.pump();

    expect(client.acquireCalls, 1);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets(
      'does not renew interaction while viewing or after leaving',
      (tester) async {
    final client = _DetailClient(
      onAcquire: (conversation) async => ConversationInteraction(
        selection:
            conversation.turnSendSelection ?? const TurnSendSelection(),
        leaseExpiresAt:
            DateTime.now().toUtc().add(const Duration(seconds: 30)),
      ),
    );
    await _pumpDetail(tester, client);
    await tester.pump();
    expect(client.acquireCalls, 1);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(client.acquireCalls, 1);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(client.acquireCalls, 1);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 20));
    expect(client.acquireCalls, 1);
    await client.close();
  });

  test('runtime reconnect clears interaction and reacquires immediately',
      () async {
    final reacquired = Completer<ConversationInteraction>();
    final conversation = _idleConversation();
    final initialClient = _DetailClient(
      onAcquire: (conversation) async => ConversationInteraction(
        selection:
            conversation.turnSendSelection ?? const TurnSendSelection(),
        leaseExpiresAt:
            DateTime.now().toUtc().add(const Duration(seconds: 30)),
      ),
    );
    final reconnectedClient = _DetailClient(
      onAcquire: (_) => reacquired.future,
    );
    final clients = [initialClient, reconnectedClient];
    var nextClient = 0;
    final session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'host',
        displayName: 'Host',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: () => clients[nextClient++],
      autoReconnect: false,
    );
    await session.connect();
    final controller = ConversationDetailController(
      session: session,
      conversation: conversation,
    );
    addTearDown(controller.dispose);
    addTearDown(session.dispose);
    await controller.reload();
    await Future<void>.delayed(Duration.zero);
    expect(initialClient.acquireCalls, 1);
    expect(controller.interactionAcquired, isTrue);

    final reconnecting = session.connect();
    await reconnecting;
    await Future<void>.delayed(Duration.zero);
    expect(reconnectedClient.acquireCalls, 1);
    expect(controller.interactionAcquired, isFalse);

    reacquired.complete(ConversationInteraction(
      selection: conversation.turnSendSelection ?? const TurnSendSelection(),
      leaseExpiresAt:
          DateTime.now().toUtc().add(const Duration(seconds: 30)),
    ));
    await Future<void>.delayed(Duration.zero);
    expect(controller.interactionAcquired, isTrue);
  });

  for (final snapshotVersion in [0, 2, 4]) {
    test('preserves observed unread activity with snapshot version $snapshotVersion',
        () async {
      final conversation = _idleConversation().withReadState(
        const ConversationReadState(
          unread: true,
          activityVersion: 'activity-3',
        ),
      );
      final client = _DetailClient(
        onGet: (_) async => ConversationSnapshot(
          detail: ConversationDetail(
            summary: _idleConversation().withReadState(ConversationReadState(
              unread: snapshotVersion != 0,
              activityVersion: 'activity-$snapshotVersion',
            )),
          ),
          snapshotCursor: 'H',
        ),
      );
      final session = DeviceSession(
        device: const PairedDevice(
          deviceId: 'host',
          displayName: 'Host',
          connectionKind: DeviceConnectionKind.demo,
        ),
        clientFactory: () => client,
        autoReconnect: false,
      );
      addTearDown(session.dispose);
      await session.connect();
      session.conversations = [conversation];
      final controller = ConversationDetailController(
        session: session,
        conversation: conversation,
      );
      addTearDown(controller.dispose);

      await controller.reload();
      await Future<void>.delayed(Duration.zero);

      final expectedVersion = snapshotVersion > 3 ? snapshotVersion : 3;
      expect(client.markReadCalls, ['activity-$expectedVersion']);
      expect(session.conversations.single.readState.unread, isFalse);
      expect(controller.detail!.summary.readState.unread, isFalse);
    });
  }

  testWidgets('acknowledges the visible activity version as read',
      (tester) async {
    final client = _DetailClient();
    final conversation = _idleConversation().withReadState(
      const ConversationReadState(
        unread: true,
        activityVersion: 'activity-3',
      ),
    );

    await _pumpDetail(tester, client, conversation: conversation);
    await tester.pumpAndSettle();

    expect(client.markReadCalls, ['activity-3']);

    client.emit(const ConversationActivityChangedEvent(
      eventCursor: 'E4',
      conversationId: 'conversation',
      activityVersion: 'activity-4',
    ));
    await tester.pumpAndSettle();

    expect(client.markReadCalls, ['activity-3', 'activity-4']);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });
}

Future<DeviceSession> _pumpDetail(
  WidgetTester tester,
  _DetailClient client, {
  ConversationSummary? conversation,
}) async {
  final session = DeviceSession(
    device: const PairedDevice(
      deviceId: 'host',
      displayName: 'Host',
      connectionKind: DeviceConnectionKind.demo,
    ),
    clientFactory: () => client,
    autoReconnect: false,
  );
  await session.connect();
  addTearDown(session.dispose);
  client.onClose = session.dispose;
  await tester.pumpWidget(MaterialApp(
    home: ConversationDetailScreen(
      session: session,
      conversation: conversation ?? _conversation,
    ),
  ));
  return session;
}

GatewayMessage _history(
  String id,
  MessageRole role,
  String kind,
  String content, {
  String? title,
  String? status,
  String? approvalStatus,
  GatewayToolInvocation? tool,
  int createdMilliseconds = 0,
}) =>
    GatewayMessage(
      id: id,
      turnId: 'turn',
      role: role,
      kind: kind,
      content: content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdMilliseconds,
        isUtc: true,
      ),
      isStreaming: false,
      title: title,
      status: status,
      approvalStatus: approvalStatus,
      tool: tool,
    );

List<GatewayMessage> _longHistory() => [
  for (var index = 0; index < 60; index++)
    _history(
      'long-$index',
      index.isEven ? MessageRole.user : MessageRole.assistant,
      'message',
      '长历史 $index ${List.filled(20, '内容 ').join()}',
      createdMilliseconds: index,
    ),
];

ScrollPosition _detailScrollPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(const Key('conversation-detail')),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable).position;
}

final _conversation = ConversationSummary(
  id: 'conversation',
  providerId: 'provider',
  title: 'Conversation',
  status: ConversationStatus.running,
  permissionLevel: PermissionLevel.readOnly,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  resource: const RoutedResourceId(
    providerId: _detailProviderId,
    nativeResourceId: 'conversation',
  ),
);

const _detailProviderId = 'provider';

const _detailProvider = GatewayProvider(
  id: _detailProviderId,
  displayName: 'Provider',
  status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'revision-1',
    methods: ['conversation.get', 'turn.send'],
    turnSend: TurnSendCapabilities(),
  ),
);

GatewayProvider _providerWith({
  required String revision,
  required TurnSendCapabilities turnSend,
}) =>
    GatewayProvider(
      id: _detailProviderId,
      displayName: 'Provider',
      status: ProviderStatus.ready,
      capabilities: GatewayCapabilities(
        revision: revision,
        methods: const ['conversation.get', 'turn.send'],
        turnSend: turnSend,
      ),
    );

ConversationSummary _idleConversation({
  TurnSendSelection? selection,
  TurnTask? activeTurn,
}) =>
    ConversationSummary(
      id: _conversation.id,
      providerId: _conversation.providerId,
      title: _conversation.title,
      status: ConversationStatus.idle,
      permissionLevel: _conversation.permissionLevel,
      createdAt: _conversation.createdAt,
      updatedAt: _conversation.updatedAt,
      activeTurn: activeTurn,
      turnSendSelection: selection,
      resource: _conversation.resource,
    );

class _ResumeDetailClient extends _DetailClient implements ConversationResumeGatewayClient {
  _ResumeDetailClient({required this.onResume});
  final Future<ConversationResumeResult> Function(ConversationSummary) onResume;
  int resumeCalls = 0;
  @override
  Future<ConversationResumeResult> resumeConversation(ConversationSummary conversation) {
    resumeCalls++;
    return onResume(conversation);
  }
}

class _DetailClient implements ConversationHistoryGatewayClient, GatewayClient, ConversationReadGatewayClient, ConversationControlGatewayClient {
  void Function()? onClose;
  Future<ConversationSnapshot> Function(String cursor)? onPage;
  final List<String> pageCalls = [];
  @override
  Future<ConversationSnapshot> getConversationPage(ConversationSummary conversation, {required String cursor}) {
    pageCalls.add(cursor);
    return onPage!(cursor);
  }
  _DetailClient({
    this.committedMessages = const [],
    this.eventDuringFirstGet,
    this.provider = _detailProvider,
    this.onGet,
    this.onAcquire,
    this.onSend,
  });

  final List<GatewayMessage> committedMessages;
  final GatewayEvent? eventDuringFirstGet;
  GatewayProvider provider;
  final Future<ConversationSnapshot> Function(ConversationSummary conversation)?
      onGet;
  final Future<ConversationInteraction> Function(ConversationSummary conversation)? onAcquire;
  final Future<TurnSendReceipt> Function(_SendCall call)? onSend;
  final StreamController<GatewayEvent> eventsController = StreamController<GatewayEvent>.broadcast(sync: true);
  final List<_SendCall> sendCalls = [];
  String _cursor = 'H';
  int getCalls = 0;
  int acquireCalls = 0;
  final List<String> markReadCalls = [];
  final List<String> interruptCalls = [];
  final List<ApprovalDecision> approvalCalls = [];

  @override Stream<GatewayEvent> get events => eventsController.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; eventsController.add(event); }
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async {
    getCalls++;
    final getHandler = onGet;
    if (getHandler != null) return getHandler(conversation);
    final snapshotCursor = _cursor;
    if (getCalls == 1 && eventDuringFirstGet != null) {
      emit(eventDuringFirstGet!);
    }
    return ConversationSnapshot(detail: ConversationDetail(summary: conversation, committedMessages: committedMessages), snapshotCursor: snapshotCursor);
  }
  @override Future<GatewayHandshake> connect() async => GatewayHandshake(protocolVersion: 1, providers: [provider], eventCursor: _cursor, deviceDescriptor: const DeviceDescriptor(deviceName: 'Test', operatingSystem: 'TestOS', systemVersion: '1'));
  @override Future<GatewayProvider> describeProvider(String providerId) async => provider;
  @override Future<ConversationPage> listConversations({required String providerId, required ConversationProjectFilter projectFilter, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationPage> searchConversations({required String providerId, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override
  Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) {
    acquireCalls++;
    final handler = onAcquire;
    return handler == null
        ? Future.value(ConversationInteraction(
            selection: conversation.turnSendSelection ?? const TurnSendSelection(),
          ))
        : handler(conversation);
  }
  @override Future<ConversationSummary> createConversation({required String providerId, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw UnimplementedError();
  @override
  Future<ConversationReadState> markConversationRead(
    ConversationSummary conversation,
  ) async {
    markReadCalls.add(conversation.readState.activityVersion);
    return ConversationReadState(
      unread: false,
      activityVersion: conversation.readState.activityVersion,
    );
  }
  @override
  Future<TurnSendReceipt> sendTurn({required String providerId, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) {
    final call = _SendCall(
      providerId: providerId,
      conversation: conversation,
      clientRequestId: clientRequestId,
      capabilityRevision: capabilityRevision,
      text: text,
      selection: selection,
    );
    sendCalls.add(call);
    final handler = onSend;
    return handler == null ? Future.value(_receipt(call)) : handler(call);
  }
  @override Future<TurnTask> interruptTurn({required ConversationSummary conversation, required TurnTask turn}) async {
    interruptCalls.add(turn.id);
    return TurnTask(id: turn.id, providerId: turn.providerId,
      conversationId: turn.conversationId, status: TurnStatus.interrupted,
      updatedAt: turn.updatedAt.add(const Duration(milliseconds: 1)),
      completedAt: turn.updatedAt.add(const Duration(milliseconds: 1)),
      resource: turn.resource, conversationResource: turn.conversationResource);
  }
  @override Future<GatewayMessage> resolveApproval({required GatewayMessage approval, required ApprovalDecision decision}) async {
    approvalCalls.add(decision);
    final status = decision == ApprovalDecision.approve ? 'approved' : 'denied';
    return GatewayMessage(id: approval.id, itemId: approval.itemId,
      turnId: approval.turnId, role: approval.role, kind: approval.kind,
      content: approval.content, createdAt: approval.createdAt, isStreaming: false,
      title: approval.title, status: status, approvalStatus: status,
      approvalDescription: approval.approvalDescription,
      approvalDecisions: approval.approvalDecisions,
      approvalDecision: decision, resource: approval.resource);
  }
  @override Future<void> close() async {
    final callback = onClose;
    onClose = null;
    callback?.call();
  }
}

class _SendCall {
  const _SendCall({
    required this.providerId,
    required this.conversation,
    required this.clientRequestId,
    required this.capabilityRevision,
    required this.text,
    required this.selection,
  });

  final String providerId;
  final ConversationSummary conversation;
  final String clientRequestId;
  final String capabilityRevision;
  final String text;
  final TurnSendSelection selection;
}

TurnSendReceipt _receipt(_SendCall call) {
  final now = DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true);
  return TurnSendReceipt(
    clientRequestId: call.clientRequestId,
    turn: TurnTask(
      id: 'turn-${call.clientRequestId}',
      providerId: call.conversation.providerId,
      conversationId: call.conversation.id,
      status: TurnStatus.queued,
      updatedAt: now,
    ),
    inputItem: GatewayMessage(
      id: 'item-${call.clientRequestId}',
      turnId: 'turn-${call.clientRequestId}',
      role: MessageRole.user,
      kind: 'message',
      content: call.text,
      createdAt: now,
      isStreaming: false,
    ),
    effectiveSelection: call.selection,
  );
}
