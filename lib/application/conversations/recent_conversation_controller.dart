import 'dart:async';

import '../../core/domain/models.dart';
import '../errors/application_failures.dart';
import '../ports/gateway_client.dart';
import '../ports/recent_conversation_gateway.dart';
import '../support/application_notifier.dart';
import '../sync/gateway_event_window.dart';

/// A provider's independent, Host-ordered recent snapshot. It never derives
/// membership from ordinary lists, timestamps, or live detail caches.
class RecentConversationController extends ApplicationNotifier {
  RecentConversationController({required this.providerId});

  final String providerId;
  static const pageSize = 20;
  GatewayClient? _client;
  GatewayEventWindow? _window;
  int? _providerGeneration;
  String? _capabilityRevision;
  int _requestGeneration = 0;
  bool _disposed = false;
  bool supported = false;
  bool loading = false;
  bool refreshing = false;
  bool loaded = false;
  Object? error;
  String? revision;
  String? _nextCursor;
  final Set<String> _consumedCursors = {};
  List<ConversationSummary> conversations = const [];
  String? anchorIdentity;

  bool get canLoadMore => supported && loaded && _nextCursor != null;
  bool get canAutoLoadMore => canLoadMore && !loading && error == null;

  void attach(GatewayClient client, GatewayProvider provider) {
    final available = provider.isAvailable &&
        provider.methods.contains('conversation.recent') &&
        client is RecentConversationGateway;
    if (identical(_client, client) &&
        _providerGeneration == provider.generation &&
        _capabilityRevision == provider.capabilities.revision &&
        supported == available) return;
    detach();
    _client = client;
    _providerGeneration = provider.generation;
    _capabilityRevision = provider.capabilities.revision;
    supported = available;
    if (available) {
      unawaited(refresh());
    } else {
      notifyApplicationListeners();
    }
  }

  void detach() {
    ++_requestGeneration;
    _client = null;
    supported = false;
    loading = false;
    refreshing = false;
    loaded = false;
    error = null;
    _nextCursor = null;
    _consumedCursors.clear();
    final window = _window;
    _window = null;
    if (window != null) unawaited(window.close());
    // Keep only the display window so UI can restore its identity/pixel anchor.
    // Its cursor is discarded and it cannot be extended after a reconnect.
  }

  bool _owns(int generation, GatewayClient client) =>
      !_disposed && generation == _requestGeneration && identical(client, _client);

  Future<void> refresh({bool retryExpired = true}) async {
    final client = _client;
    if (!supported || client == null || client is! RecentConversationGateway) return;
    final generation = ++_requestGeneration;
    final restoreCount = conversations.length;
    _nextCursor = null;
    loading = true;
    refreshing = true;
    error = null;
    final previousWindow = _window;
    final window = client.openEventWindow();
    _window = window;
    if (previousWindow != null) unawaited(previousWindow.close());
    notifyApplicationListeners();
    try {
      final gateway = client as RecentConversationGateway;
      var page = await gateway.recentConversations(providerId: providerId, limit: pageSize);
      if (!_owns(generation, client)) return;
      final snapshotRevision = page.revision;
      window.install(
        baselineCursor: window.startCursor ?? page.snapshotCursor,
        snapshotCursor: page.snapshotCursor,
        onEvent: (incoming) {
          if (!_owns(generation, client)) return;
          final event = incoming is ObservedGatewayEvent ? incoming.event : incoming;
          if (event is RecentConversationsChangedEvent &&
              event.providerId == providerId && event.revision != snapshotRevision) {
            unawaited(refresh());
          }
        },
        onError: (value, stack) {
          if (!_owns(generation, client)) return;
          ++_requestGeneration;
          _nextCursor = null;
          loading = false;
          refreshing = false;
          error = value;
          notifyApplicationListeners();
        },
      );
      if (!_owns(generation, client)) return;
      final replacement = <ConversationSummary>[];
      final seen = <String>{};
      final cursors = <String>{};
      _append(replacement, seen, page.conversations);
      while ((replacement.length < restoreCount ||
              anchorIdentity != null && !seen.contains(anchorIdentity)) &&
          page.nextCursor != null) {
        final cursor = page.nextCursor!;
        if (!cursors.add(cursor)) throw const FormatException('最近分页游标重复');
        page = await gateway.recentConversations(providerId: providerId, cursor: cursor, limit: pageSize);
        if (!_owns(generation, client)) return;
        if (page.revision != snapshotRevision) throw const FormatException('最近分页快照已变化');
        _append(replacement, seen, page.conversations);
      }
      if (page.nextCursor != null && cursors.contains(page.nextCursor)) {
        throw const FormatException('最近分页游标重复');
      }
      conversations = List.unmodifiable(replacement);
      _consumedCursors
        ..clear()
        ..addAll(cursors);
      revision = snapshotRevision;
      _nextCursor = page.nextCursor;
      loaded = true;
    } catch (value) {
      if (!_owns(generation, client)) return;
      if (retryExpired && value is GatewayProtocolException &&
          value.code == 'recent_cursor_expired') {
        await refresh(retryExpired: false);
        return;
      }
      error = value;
    } finally {
      if (_owns(generation, client)) {
        loading = false;
        refreshing = false;
        notifyApplicationListeners();
      }
    }
  }

  Future<void> loadMore() async {
    final client = _client;
    final cursor = _nextCursor;
    if (!canLoadMore || loading || client == null || cursor == null) return;
    final generation = _requestGeneration;
    loading = true;
    error = null;
    notifyApplicationListeners();
    try {
      final page = await (client as RecentConversationGateway).recentConversations(
        providerId: providerId, cursor: cursor, limit: pageSize,
      );
      if (!_owns(generation, client)) return;
      if (page.revision != revision) {
        await refresh();
        return;
      }
      if (page.nextCursor == cursor || _consumedCursors.contains(page.nextCursor)) {
        throw const FormatException('最近分页游标重复');
      }
      _consumedCursors.add(cursor);
      final next = [...conversations];
      _append(next, next.map(_identity).toSet(), page.conversations);
      conversations = List.unmodifiable(next);
      _nextCursor = page.nextCursor;
    } catch (value) {
      if (!_owns(generation, client)) return;
      if (value is GatewayProtocolException && value.code == 'recent_cursor_expired') {
        await refresh();
        return;
      }
      error = value;
    } finally {
      if (_owns(generation, client)) {
        loading = false;
        notifyApplicationListeners();
      }
    }
  }

  Future<void> retry() => _nextCursor != null && loaded ? loadMore() : refresh();

  static String _identity(ConversationSummary conversation) =>
      conversation.resource?.key ?? '${conversation.providerId}\u0000${conversation.id}';

  static void _append(List<ConversationSummary> target, Set<String> seen,
      List<ConversationSummary> incoming) {
    for (final conversation in incoming) {
      if (seen.add(_identity(conversation))) target.add(conversation);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    detach();
    super.dispose();
  }
}
