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
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', outputId: 'output', kind: 'text', delta: 'live-only'));
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
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', outputId: 'output', kind: 'text', delta: 'stale-live'));
    await tester.pump();
    client.eventsController.addError(StateError('socket lost'));
    await tester.pump();
    expect(find.text('stale-live'), findsNothing);
    expect(find.textContaining('socket lost'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });
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
  final StreamController<GatewayEvent> eventsController = StreamController<GatewayEvent>.broadcast(sync: true);
  String _cursor = 'H';
  int getCalls = 0;

  @override Stream<GatewayEvent> get events => eventsController.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; eventsController.add(event); }
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async {
    getCalls++;
    return ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: _cursor);
  }
  @override Future<GatewayHandshake> connect() => throw UnimplementedError();
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<void> close() => eventsController.close();
}
