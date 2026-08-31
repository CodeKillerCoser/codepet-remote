import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationDetail event projection', () {
    final summary = ConversationSummary.fromJson(_conversationJson());

    test('merges output deltas by output id', () {
      var detail = ConversationDetail(summary: summary);

      detail = detail.apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-8',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          outputId: 'output-1',
          kind: 'text',
          delta: 'hello ',
        ),
      );
      detail = detail.apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-9',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          outputId: 'output-1',
          kind: 'text',
          delta: 'world',
        ),
      );

      expect(detail.messages, hasLength(1));
      expect(detail.messages.single.content, 'hello world');
      expect(detail.messages.single.isStreaming, isTrue);
      expect(detail.lastEventCursor, 'event-9');
    });

    test('keeps live output separate until a terminal snapshot is installed', () {
      var detail = ConversationDetail(summary: summary).apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-8',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          outputId: 'output-1',
          kind: 'text',
          delta: 'done',
        ),
      );

      detail = detail.apply(
        TurnUpsertedEvent(
          eventCursor: 'event-9',
          turn: TurnTask(
            id: 'turn-1',
            providerId: 'codex',
            conversationId: 'conversation-1',
            status: TurnStatus.completed,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
            completedAt: DateTime.fromMillisecondsSinceEpoch(
              3000,
              isUtc: true,
            ),
          ),
        ),
      );

      expect(detail.liveOutputMessages.single.isStreaming, isTrue);
      expect(detail.turns.single.status, TurnStatus.completed);

      final committed = GatewayMessage(
        id: 'history',
        turnId: 'turn-1',
        role: MessageRole.assistant,
        kind: 'text',
        content: 'committed',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
        isStreaming: false,
      );
      detail = detail.installCommittedSnapshot(
        ConversationDetail(summary: summary, committedMessages: [committed]),
        completedTurnId: 'turn-1',
      );
      expect(detail.committedMessages, [committed]);
      expect(detail.liveOutputMessages, isEmpty);
    });

    test('does not merge equal output ids from different routed turns', () {
      var detail = ConversationDetail(summary: summary);
      for (final turnId in ['turn-a', 'turn-b']) {
        detail = detail.apply(TurnOutputDeltaEvent(
          eventCursor: 'cursor-$turnId',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: turnId,
          outputId: 'same-output',
          kind: 'text',
          delta: turnId,
        ));
      }
      expect(detail.liveOutputMessages, hasLength(2));
      expect(detail.liveOutputMessages.map((message) => message.turnId), ['turn-a', 'turn-b']);
    });

    test('ignores events for another conversation', () {
      final detail = ConversationDetail(summary: summary);
      final next = detail.apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-8',
          providerId: 'codex',
          conversationId: 'conversation-2',
          turnId: 'turn-2',
          outputId: 'output-2',
          kind: 'text',
          delta: 'unrelated',
        ),
      );

      expect(identical(next, detail), isTrue);
    });
  });

}

Map<String, dynamic> _conversationJson() {
  return {
    'id': 'conversation-1',
    'providerId': 'codex',
    'title': 'Test conversation',
    'preview': 'Preview',
    'status': 'running',
    'permissionLevel': 'workspace-write',
    'createdAt': 1000,
    'updatedAt': 2000,
  };
}
