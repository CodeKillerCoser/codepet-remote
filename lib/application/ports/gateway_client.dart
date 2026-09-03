import 'dart:async';

import '../sync/gateway_event_window.dart';
import '../../core/domain/models.dart';

/// Application-facing contract implemented by Gateway infrastructure.
abstract interface class GatewayClient {
  Stream<GatewayEvent> get events;
  String? get latestEventCursor;
  GatewayEventWindow openEventWindow();
  Future<GatewayHandshake> connect();
  Future<GatewayProvider> describeProvider(String providerId);
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  });
  Future<ConversationPage> searchConversations({
    required String providerId,
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
    required String providerId,
    String? title,
    required String permissionLevel,
    String? model,
    String? reasoningEffort,
    String? workspaceRoot,
    String? workspaceMode,
    RoutedResourceId? project,
  });
  Future<TurnSendReceipt> sendTurn({
    required String providerId,
    required ConversationSummary conversation,
    required String clientRequestId,
    required String capabilityRevision,
    required String text,
    required TurnSendSelection selection,
  });
  Future<void> close();
}

/// Optional project surface implemented only by Providers backed by a Gateway
/// SDK that exposes project methods.
abstract interface class ProjectGatewayClient {
  Future<ProjectPage> listProjects({
    required String providerId,
    String? cursor,
    int limit = 50,
  });

  Future<GatewayProject> getProject(RoutedResourceId project);

  Future<GatewayProject> createProject({
    required String providerId,
    required String idempotencyKey,
    required String name,
    required List<ProjectRoot> roots,
    Map<String, String> metadata = const {},
  });

  Future<GatewayProject> updateProject({
    required RoutedResourceId project,
    String? name,
    List<ProjectRoot>? roots,
    Map<String, String>? metadata,
  });

  Future<void> deleteProject(RoutedResourceId project);
}

abstract interface class ConversationReadGatewayClient {
  Future<ConversationReadState> markConversationRead(
    ConversationSummary conversation,
  );
}

class ConversationSnapshot {
  const ConversationSnapshot({
    required this.detail,
    required this.snapshotCursor,
  });

  final ConversationDetail detail;
  final String snapshotCursor;
}
