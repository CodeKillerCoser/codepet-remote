import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConversationDetail event projection', () {
    final summary = ConversationSummary.fromJson(_conversationJson());

    test('merges output deltas by output id', () {
      var detail = ConversationDetail(summary: summary);

      detail = detail.apply(
        const TurnOutputDeltaEvent(
          sequence: 8,
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
          sequence: 9,
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
      expect(detail.lastEventSequence, 9);
    });

    test('marks streamed output complete with the turn event', () {
      var detail = ConversationDetail(summary: summary).apply(
        const TurnOutputDeltaEvent(
          sequence: 8,
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
          sequence: 9,
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

      expect(detail.messages.single.isStreaming, isFalse);
      expect(detail.turns.single.status, TurnStatus.completed);
    });

    test('ignores events for another conversation', () {
      final detail = ConversationDetail(summary: summary);
      final next = detail.apply(
        const TurnOutputDeltaEvent(
          sequence: 8,
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
