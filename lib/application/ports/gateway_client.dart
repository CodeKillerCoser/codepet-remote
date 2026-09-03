import 'dart:async';

import '../sync/gateway_event_window.dart';
import '../../core/domain/models.dart';

/// Application-facing contract implemented by Gateway infrastructure.
abstract interface class GatewayClient {
  Stream<GatewayEvent> get events;
  String? get latestEventCursor;
  GatewayEventWindow openEventWindow();
  Future<GatewayHandshake> connect();
  Future<ConversationPage> listConversations({
    required GatewayProviderRoute route,
    String? cursor,
    int limit = 50,
  });
  Future<ConversationPage> searchConversations({
    required GatewayProviderRoute route,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  });
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  );
  Future<ConversationInteraction> acquireInteraction(
    ConversationSummary conversation,
  );
  Future<ConversationSummary> createConversation({
    required GatewayProviderRoute route,
    String? title,
    required String permissionLevel,
    String? model,
    String? reasoningEffort,
    String? workspaceRoot,
    String? workspaceMode,
  });
  Future<TurnSendReceipt> sendTurn({
    required GatewayProviderRoute route,
    required ConversationSummary conversation,
    required String clientRequestId,
    required String capabilityRevision,
    required String text,
    required TurnSendSelection selection,
  });
  Future<void> close();
}

class ConversationSnapshot {
  const ConversationSnapshot({
    required this.detail,
    required this.snapshotCursor,
  });

  final ConversationDetail detail;
  final String snapshotCursor;
}
