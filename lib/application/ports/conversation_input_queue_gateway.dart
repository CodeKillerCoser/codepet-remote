import '../../core/domain/models.dart';
import '../../core/domain/conversation_input_queue.dart';

abstract interface class ConversationInputQueueGatewayClient {
  Future<ConversationInputQueue> getInputQueue(
    ConversationSummary conversation,
  );
  Future<ConversationQueuedInput> enqueueInput(
    ConversationSummary conversation,
    PendingQueueSubmission submission,
  );
  Future<ConversationQueuedInput> withdrawInput(
    ConversationSummary conversation, {
    required String itemId,
    required String requestId,
    required int expectedRevision,
    required bool edit,
  });
  Future<ConversationQueuedInput> steerInput(
    ConversationSummary conversation, {
    required String itemId,
    required String requestId,
    required int expectedRevision,
    required TurnTask turn,
    required String capabilityRevision,
  });
  Future<ConversationInputQueue> resumeInputQueue(
    ConversationSummary conversation, {
    required int expectedRevision,
  });
  Future<ConversationInputQueue> acknowledgeInputEdit(
    ConversationSummary conversation, {
    required String itemId,
  });
}
