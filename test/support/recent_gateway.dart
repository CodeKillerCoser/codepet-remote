import 'dart:async';

import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/ports/recent_conversation_gateway.dart';
import 'package:codepet_remote/application/sync/gateway_event_window.dart';
import 'package:codepet_remote/core/domain/models.dart';

const recentProvider = GatewayProvider(
  id: 'test', displayName: 'Test', status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'capability-1', methods: ['conversation.list', 'conversation.recent'],
  ),
);

ConversationSummary recentItem(String id) => ConversationSummary(
  id: id, providerId: 'test', title: id, status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.readOnly,
  // Deliberately old and read: Remote must still accept the Host's result.
  createdAt: DateTime.utc(2020), updatedAt: DateTime.utc(2020),
);

RecentConversationPage recentPage(List<String> ids, {
  String revision = 'r1', String? nextCursor, String snapshotCursor = 'e0',
}) => RecentConversationPage(
  conversations: ids.map(recentItem).toList(), revision: revision,
  nextCursor: nextCursor, snapshotCursor: snapshotCursor,
);

class RecentGatewayFake implements GatewayClient, RecentConversationGateway {
  final stream = StreamController<GatewayEvent>.broadcast(sync: true);
  final requests = <(String?, Completer<RecentConversationPage>)>[];
  final listFilters = <ConversationProjectFilter>[];
  String cursor = 'e0';

  @override Stream<GatewayEvent> get events => stream.stream;
  @override String? get latestEventCursor => cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(cursor, events);
  @override Future<RecentConversationPage> recentConversations({
    required String providerId, String? cursor, int limit = 20,
  }) {
    final result = Completer<RecentConversationPage>();
    requests.add((cursor, result));
    return result.future;
  }

  void change(String revision) {
    cursor = 'e${int.parse(cursor.substring(1)) + 1}';
    stream.add(RecentConversationsChangedEvent(
      eventCursor: cursor, providerId: 'test', revision: revision,
    ));
  }

  @override Future<GatewayHandshake> connect() async => const GatewayHandshake(
    protocolVersion: 1, providers: [recentProvider], eventCursor: 'e0',
    deviceDescriptor: DeviceDescriptor(deviceName: 'Test', operatingSystem: 'Test', systemVersion: '1'),
  );
  @override Future<ConversationPage> listConversations({
    required String providerId, required ConversationProjectFilter projectFilter,
    String? cursor, int limit = 50,
  }) async {
    listFilters.add(projectFilter);
    return ConversationPage(conversations: [recentItem('old-chat')],
      snapshotCursor: this.cursor, nextCursor: cursor == null ? 'chat-next' : null);
  }
  @override Future<void> close() => stream.close();
  @override dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
