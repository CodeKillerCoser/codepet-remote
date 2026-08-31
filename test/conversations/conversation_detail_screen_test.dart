import 'dart:async';

import 'package:codepet_remote/features/conversations/conversation_detail_screen.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    await tester.pumpWidget(MaterialApp(
      home: ConversationDetailScreen(
        client: client,
        conversation: _conversation,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-history-0')), findsNothing);
    expect(find.byKey(const Key('message-history-44')), findsOneWidget);

    final position = _detailScrollPosition(tester);
    position.jumpTo(0);
    await tester.pump();
    expect(find.byKey(const Key('show-earlier-messages')), findsOneWidget);
    await tester.tap(find.byKey(const Key('show-earlier-messages')));
    await tester.pump();
    await tester.pump();

    position.jumpTo(0);
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
    await tester.pumpWidget(MaterialApp(
      home: ConversationDetailScreen(
        client: client,
        conversation: _conversation,
      ),
    ));
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

  testWidgets('collapses history and accumulates new output while collapsed', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history('one', MessageRole.user, 'message', '第一条'),
        _history('two', MessageRole.assistant, 'message', '第二条'),
      ],
    );
    await tester.pumpWidget(MaterialApp(
      home: ConversationDetailScreen(
        client: client,
        conversation: _conversation,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('messages-section-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('message-one')), findsNothing);
    expect(find.byKey(const Key('message-two')), findsNothing);

    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'collapsed-live',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'collapsed-turn',
      itemId: 'collapsed-item',
      contentId: 'collapsed-item:text',
      kind: 'text',
      delta: '折叠期间的新消息',
    ));
    await tester.pump();
    expect(find.text('折叠期间的新消息'), findsNothing);

    await tester.tap(find.byKey(const Key('messages-section-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('折叠期间的新消息'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('shows a scroll-to-bottom button and scrolls on tap', (tester) async {
    final client = _DetailClient(
      committedMessages: _longHistory(),
    );
    await tester.pumpWidget(MaterialApp(
      home: ConversationDetailScreen(
        client: client,
        conversation: _conversation,
      ),
    ));
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
    await tester.pumpWidget(MaterialApp(
      home: ConversationDetailScreen(
        client: client,
        conversation: _conversation,
      ),
    ));
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

  testWidgets('terminal turn refresh clears only its in-memory live output', (tester) async {
    final client = _DetailClient();
    await tester.pumpWidget(MaterialApp(home: ConversationDetailScreen(client: client, conversation: _conversation)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', itemId: 'item', contentId: 'item:text', kind: 'text', delta: 'live-only'));
    await tester.pump();
    expect(find.text('live-only'), findsOneWidget);

    client.emit(TurnUpsertedEvent(eventCursor: 'terminal', turn: TurnTask(id: 'turn', providerId: 'provider', conversationId: 'conversation', status: TurnStatus.completed, updatedAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.getCalls, 2);
    expect(find.text('live-only'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('event stream failure discards stale detail and live output', (tester) async {
    final client = _DetailClient();
    await tester.pumpWidget(MaterialApp(home: ConversationDetailScreen(client: client, conversation: _conversation)));
    await tester.pumpAndSettle();
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', itemId: 'item', contentId: 'item:text', kind: 'text', delta: 'stale-live'));
    await tester.pump();
    client.eventsController.addError(StateError('socket lost'));
    await tester.pump();
    expect(find.text('stale-live'), findsNothing);
    expect(find.textContaining('socket lost'), findsOneWidget);
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
    await tester.pumpWidget(MaterialApp(home: ConversationDetailScreen(client: client, conversation: _conversation)));
    await tester.pumpAndSettle();

    expect(find.text('Show the history.'), findsOneWidget);
    expect(find.text('History is ready.'), findsOneWidget);
    expect(find.text('Run git status --short'), findsWidgets);
    expect(find.text('Approve command'), findsOneWidget);
    expect(find.text('已批准'), findsOneWidget);
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

    await tester.pumpWidget(MaterialApp(home: ConversationDetailScreen(client: client, conversation: _conversation)));
    await tester.pumpAndSettle();

    expect(find.text('committed body'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });
}

GatewayMessage _history(
  String id,
  MessageRole role,
  String kind,
  String content, {
  String? title,
  String? status,
  String? approvalStatus,
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
);

class _DetailClient implements GatewayClient {
  _DetailClient({
    this.committedMessages = const [],
    this.eventDuringFirstGet,
  });

  final List<GatewayMessage> committedMessages;
  final GatewayEvent? eventDuringFirstGet;
  final StreamController<GatewayEvent> eventsController = StreamController<GatewayEvent>.broadcast(sync: true);
  String _cursor = 'H';
  int getCalls = 0;

  @override Stream<GatewayEvent> get events => eventsController.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; eventsController.add(event); }
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async {
    getCalls++;
    final snapshotCursor = _cursor;
    if (getCalls == 1 && eventDuringFirstGet != null) {
      emit(eventDuringFirstGet!);
    }
    return ConversationSnapshot(detail: ConversationDetail(summary: conversation, committedMessages: committedMessages), snapshotCursor: snapshotCursor);
  }
  @override Future<GatewayHandshake> connect() => throw UnimplementedError();
  @override Future<ConversationPage> listConversations({required GatewayProviderRoute route, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<void> close() => eventsController.close();
}
