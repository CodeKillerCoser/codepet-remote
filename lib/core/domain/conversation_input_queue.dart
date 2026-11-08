import 'models.dart';

class ConversationQueuedInput {
  const ConversationQueuedInput({
    required this.id,
    required this.sequence,
    required this.text,
    required this.selection,
    required this.capabilityRevision,
    required this.state,
    required this.createdAt,
    this.targetTurn,
    this.errorCode,
    this.errorMessage,
  });
  final String id;
  final int sequence;
  final String text;
  final TurnSendSelection selection;
  final String capabilityRevision;
  final String state;
  final DateTime createdAt;
  final RoutedResourceId? targetTurn;
  final String? errorCode;
  final String? errorMessage;
  bool get editable => state == 'queued' || state == 'blocked';
  bool get uncertain => state == 'outcomeUnknown';
}

class ConversationInputQueue {
  const ConversationInputQueue({
    required this.conversation,
    required this.revision,
    required this.paused,
    required this.items,
    required this.recoverableEdits,
    required this.snapshotCursor,
  });
  final RoutedResourceId conversation;
  final int revision;
  final bool paused;
  final List<ConversationQueuedInput> items;
  final List<ConversationQueuedInput> recoverableEdits;
  final String snapshotCursor;
}

class PendingQueueSubmission {
  const PendingQueueSubmission({
    required this.requestId,
    required this.text,
    required this.selection,
    required this.capabilityRevision,
  });
  final String requestId;
  final String text;
  final TurnSendSelection selection;
  final String capabilityRevision;
}

class ConversationDraftBackup {
  const ConversationDraftBackup(this.text, this.selection);
  final String text;
  final TurnSendSelection selection;
}
