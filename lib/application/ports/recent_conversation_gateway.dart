import '../../core/domain/models.dart';

/// Optional Gateway aggregation surface. Ordering and membership belong to Host.
abstract interface class RecentConversationGateway {
  Future<RecentConversationPage> recentConversations({
    required String providerId,
    String? cursor,
    int limit = 20,
  });
}

class RecentConversationPage {
  const RecentConversationPage({
    required this.conversations,
    required this.revision,
    required this.snapshotCursor,
    this.nextCursor,
  });

  final List<ConversationSummary> conversations;
  final String revision;
  final String snapshotCursor;
  final String? nextCursor;
}

final class RecentConversationsChangedEvent extends GatewayEvent {
  const RecentConversationsChangedEvent({
    required super.eventCursor,
    required this.providerId,
    required this.revision,
  });

  final String providerId;
  final String revision;
}
