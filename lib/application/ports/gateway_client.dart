import 'dart:async';

import '../sync/gateway_event_window.dart';
import '../../core/domain/models.dart';
import 'trace_recorder.dart';

final class ObservedGatewayEvent extends GatewayEvent {
  ObservedGatewayEvent({
    required this.event,
    this.traceContext,
    required this.receivedAt,
  }) : super(eventCursor: event.eventCursor);

  final GatewayEvent event;
  final TraceCorrelation? traceContext;
  final DateTime receivedAt;
}

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

abstract interface class ConversationHistoryGatewayClient {
  Future<ConversationSnapshot> getConversationPage(
    ConversationSummary conversation, {
    required String cursor,
  });
}

/// Combined conversation entry; successful interaction does not require renewal.
abstract interface class ConversationResumeGatewayClient {
  Future<ConversationResumeResult> resumeConversation(
    ConversationSummary conversation,
  );
}

class ConversationResumeResult {
  const ConversationResumeResult({
    this.interaction,
    this.interactionError,
    this.loadHistory,
  });

  final ConversationInteraction? interaction;
  final Object? interactionError;
  // Uses only the returned first page; older pages require explicit navigation.
  final Future<ConversationSnapshot> Function()? loadHistory;
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

/// Optional write surface for active turns and pending approvals.
abstract interface class ConversationControlGatewayClient {
  Future<TurnTask> interruptTurn({
    required ConversationSummary conversation,
    required TurnTask turn,
  });

  Future<GatewayMessage> resolveApproval({
    required GatewayMessage approval,
    required ApprovalDecision decision,
  });
}

class ConversationSnapshot {
  const ConversationSnapshot({
    required this.detail,
    required this.snapshotCursor,
    this.nextCursor,
  });

  final ConversationDetail detail;
  final String snapshotCursor;
  final String? nextCursor;
}

/// Provider presence snapshots are control data, separate from replayable conversation events.
abstract interface class ProviderSnapshotGatewayClient {
  Stream<List<GatewayProvider>> get providerSnapshots;
}
