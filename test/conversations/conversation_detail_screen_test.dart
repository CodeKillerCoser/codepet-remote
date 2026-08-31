import 'dart:async';

import 'package:codepet_remote/features/conversations/conversation_detail_screen.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}) =>
    GatewayMessage(
      id: id,
      turnId: 'turn',
      role: role,
      kind: kind,
      content: content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      isStreaming: false,
      title: title,
      status: status,
      approvalStatus: approvalStatus,
    );

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
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<void> close() => eventsController.close();
}
