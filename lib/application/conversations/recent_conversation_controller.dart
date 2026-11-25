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
  // This bounds anchor recovery, not feed membership or ordinary pagination.
  static const anchorLookaheadPages = 5;
  GatewayClient? _client;
  GatewayEventWindow? _window;
  int? _providerGeneration;
  String? _capabilityRevision;
  int _requestGeneration = 0;
  bool _disposed = false;
  bool _active = true;
  bool _refreshPending = false;
  bool _snapshotStale = false;
  final Map<String, ConversationSummary> _liveSummaries = {};
  bool supported = false;
  bool loading = false;
  bool refreshing = false;
  bool loaded = false;
  Object? error;
  String? revision;
  String? _nextCursor;
  final Set<String> _consumedCursors = {};
  int _automaticRecoveries = 0;
  Object? _automaticRecoveryError;
  List<ConversationSummary> conversations = const [];
  List<String> anchorCandidates = const [];

  bool get canLoadMore => supported && loaded && _nextCursor != null;
  bool get canAutoLoadMore => _active && canLoadMore && !loading && error == null;

  void setActive(bool active) {
    _active = active;
    if (active && _refreshPending) unawaited(refresh());
  }

  void attach(GatewayClient client, GatewayProvider provider) {
    final available = provider.isAvailable &&
        provider.methods.contains('conversation.recent') &&
        client is RecentConversationGateway;
    if (identical(_client, client) &&
        _providerGeneration == provider.generation &&
        _capabilityRevision == provider.capabilities.revision &&
        supported == available) {
      return;
    }
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
    _automaticRecoveries = 0;
    _automaticRecoveryError = null;
    _refreshPending = false;
    _snapshotStale = false;
    _liveSummaries.clear();
    final window = _window;
    _window = null;
    if (window != null) unawaited(window.close());
    // Keep only the display window so UI can restore its identity/pixel anchor.
    // Its cursor is discarded and it cannot be extended after a reconnect.
  }

  bool _owns(int generation, GatewayClient client) =>
      !_disposed && generation == _requestGeneration && identical(client, _client);

  Future<void> refresh() async {
    if (!_active) {
      _refreshPending = true;
      return;
    }
    final client = _client;
    if (!supported || client == null || client is! RecentConversationGateway) return;
    if (loading) return;
    _refreshPending = false;
    _snapshotStale = false;
    _liveSummaries.clear();
    final generation = ++_requestGeneration;
    final restoreCount = conversations.length;
    _nextCursor = null;
    loaded = false;
    loading = true;
    refreshing = true;
    // A successful first page is not proof that the following cursor works.
    // Keep an exhausted recovery cycle paused even through invalidations.
    error = _automaticRecoveryError;
    final previousWindow = _window;
    final window = client.openEventWindow();
    _window = window;
    if (previousWindow != null) unawaited(previousWindow.close());
    notifyApplicationListeners();
    try {
      final baselineCursor = window.startCursor;
      if (baselineCursor == null) {
        throw const GatewayCursorGapException('最近列表缺少事件订阅起点');
      }
      final gateway = client as RecentConversationGateway;
      var page = await gateway.recentConversations(providerId: providerId, limit: pageSize);
      if (!_owns(generation, client)) return;
      final snapshotRevision = page.revision;
      window.install(
        baselineCursor: baselineCursor,
        snapshotCursor: page.snapshotCursor,
        onEvent: (incoming) {
          if (!_owns(generation, client)) return;
          final event = incoming is ObservedGatewayEvent ? incoming.event : incoming;
          if (event is RecentConversationsChangedEvent &&
              event.providerId == providerId && event.revision != snapshotRevision) {
            // Keep the display, but never continue a cursor invalidated by the
            // Host. Passive hints must not start another query.
            _snapshotStale = true;
            _nextCursor = null;
            notifyApplicationListeners();
          } else if (event is ConversationUpsertedEvent &&
              event.conversation.providerId == providerId) {
            final row = event.conversation;
            final key = _identity(row);
            _liveSummaries.remove(key);
            _liveSummaries[key] = row;
            if (_liveSummaries.length > 512) _liveSummaries.remove(_liveSummaries.keys.first);
            // Host queries alone determine membership and ordering. Events only
            // update rows already present, without pulling any list or history.
            conversations = List.unmodifiable([
              for (final current in conversations)
                if (_identity(current) == key) _mergeLive(current) else current,
            ]);
            notifyApplicationListeners();
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
      var anchorLookahead = 0;
      _append(replacement, seen, page.conversations);
      while (!_snapshotStale && (replacement.length < restoreCount ||
              anchorCandidates.isNotEmpty &&
                  !anchorCandidates.any(seen.contains) &&
                  anchorLookahead < anchorLookaheadPages) &&
          page.nextCursor != null) {
        if (!_active) {
          _refreshPending = true;
          return;
        }
        if (replacement.length >= restoreCount) anchorLookahead++;
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
      conversations = List.unmodifiable(replacement.map(_mergeLive));
      _consumedCursors
        ..clear()
        ..addAll(cursors);
      revision = snapshotRevision;
      _nextCursor = _snapshotStale ? null : page.nextCursor;
      loaded = true;
    } catch (value) {
      if (!_owns(generation, client)) return;
      if (!_snapshotStale && value is GatewayProtocolException &&
          value.code == 'recent_cursor_expired') {
        await _recoverSnapshot(value);
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
    if (!_active || !canLoadMore || loading || _automaticRecoveryError != null ||
        client == null || cursor == null) {
      return;
    }
    final generation = _requestGeneration;
    loading = true;
    error = null;
    notifyApplicationListeners();
    try {
      final page = await (client as RecentConversationGateway).recentConversations(
        providerId: providerId, cursor: cursor, limit: pageSize,
      );
      if (!_owns(generation, client)) return;
      if (_snapshotStale) return;
      if (page.revision != revision) {
        await _recoverSnapshot(const FormatException('最近分页快照已变化'));
        return;
      }
      if (page.nextCursor == cursor || _consumedCursors.contains(page.nextCursor)) {
        throw const FormatException('最近分页游标重复');
      }
      _consumedCursors.add(cursor);
      final next = [...conversations];
      _append(next, next.map(_identity).toSet(), page.conversations);
      if (next.length > conversations.length || page.nextCursor == null) {
        _automaticRecoveries = 0;
        _automaticRecoveryError = null;
      }
      conversations = List.unmodifiable(next.map(_mergeLive));
      _nextCursor = page.nextCursor;
    } catch (value) {
      if (!_owns(generation, client)) return;
      if (_snapshotStale) return;
      if (value is GatewayProtocolException && value.code == 'recent_cursor_expired') {
        await _recoverSnapshot(value);
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

  Future<void> _recoverSnapshot(Object cause) async {
    _nextCursor = null;
    if (_automaticRecoveries >= 1) {
      _automaticRecoveryError = cause;
      error = cause;
      return;
    }
    _automaticRecoveries++;
    loading = false;
    await refresh();
  }

  Future<void> retry() {
    if (loading) return Future.value();
    _automaticRecoveries = 0;
    _automaticRecoveryError = null;
    return _nextCursor != null && loaded ? loadMore() : refresh();
  }

  static String _identity(ConversationSummary conversation) =>
      conversation.resource?.key ?? '${conversation.providerId}\u0000${conversation.id}';

  ConversationSummary _mergeLive(ConversationSummary row) {
    final live = _liveSummaries[_identity(row)];
    return live == null ? row : live.withReadState(row.readState.merge(live.readState));
  }

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
