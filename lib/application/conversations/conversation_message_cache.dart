import 'dart:async';

import '../../core/domain/models.dart';
import '../ports/gateway_client.dart';
import '../support/application_notifier.dart';
import '../sync/gateway_event_window.dart';

/// A session owns these sources, so leaving a screen does not lose live output.
class ConversationMessageSource extends ApplicationNotifier {
  ConversationMessageSource(this.detail, this.scope, this.lastAccess);

  ConversationDetail detail;
  final Object scope;
  DateTime lastAccess;
  int readers = 0;
  bool initialized = false;
  bool interactionAcquired = false;
  Future<ConversationDetail> Function()? loadLatest;
  bool _refreshing = false;
  bool _refreshPending = false;
  final Set<String> _changedDuringRefresh = {};
  int version = 0;
  Completer<void>? initialLoad;
  bool loadingEarlier = false;
  bool closed = false;
  String? nextCursor;
  String? historyError;
  String? streamError;
  GatewayEventWindow? window;
  GatewayEvent? lastEvent;
  final Set<String> loadedCursors = {};

  void applyEvent(GatewayEvent incoming) {
    if (closed) return;
    final event = incoming is ObservedGatewayEvent ? incoming.event : incoming;
    if (event is ConversationItemUpsertedEvent && event.item == null &&
        event.conversationId == detail.summary.id) {
      if (!interactionAcquired && loadLatest != null) {
        _refreshPending = true;
        unawaited(_refreshLatest());
      }
      return;
    }
    if (_refreshing) {
      if (event is ConversationItemUpsertedEvent && event.item != null && event.conversationId == detail.summary.id) {
        final item = event.item!;
        _changedDuringRefresh.add('${item.turnId}\u0000${item.itemId ?? item.id}');
      } else if (event is TurnOutputDeltaEvent && event.conversationId == detail.summary.id) {
        _changedDuringRefresh.add('${event.turnId}\u0000${event.itemId}');
      }
    }
    var next = detail.apply(event);
    if (identical(next, detail)) return;
    if (!interactionAcquired && event is ConversationUpsertedEvent &&
        next.summary.activeTurn == null) {
      // External lifecycle facts have no native turn identity. Retire stale
      // active projections without manufacturing a terminal turn or losing text.
      final ended = next.summary.status == ConversationStatus.idle;
      next = ConversationDetail(summary: next.summary,
        committedMessages: ended ? [for (final item in next.committedMessages) item.copyWith(isStreaming: false)] : next.committedMessages,
        liveOutputMessages: ended ? [for (final item in next.liveOutputMessages) item.copyWith(isStreaming: false)] : next.liveOutputMessages,
        turns: next.turns.where((turn) => turn.status.isTerminal).toList(),
        messageOrder: next.messageOrder, lastEventCursor: next.lastEventCursor);
    }
    detail = next;
    lastEvent = incoming;
    notifyApplicationListeners();
  }

  Future<void> _refreshLatest() async {
    if (_refreshing) return;
    _refreshing = true;
    final expectedVersion = version;
    try {
      while (_refreshPending && !closed && !interactionAcquired && version == expectedVersion) {
        _refreshPending = false;
        _changedDuringRefresh.clear();
        final page = await loadLatest!();
        if (closed || interactionAcquired || version != expectedVersion) return;
        // Canonical upserts preserve older pages, item identity and pagination/fence.
        for (final item in page.committedMessages) {
          if (_changedDuringRefresh.contains('${item.turnId}\u0000${item.itemId ?? item.id}')) continue;
          detail = detail.apply(ConversationItemUpsertedEvent(
            eventCursor: detail.lastEventCursor ?? '', conversationId: detail.summary.id, item: item));
        }
        historyError = null;
        notifyApplicationListeners();
      }
    } catch (error) {
      if (!closed && version == expectedVersion && !interactionAcquired) {
        historyError = '更新消息失败：$error';
        notifyApplicationListeners();
      }
    } finally {
      _refreshing = false;
    }
  }

  @override
  void dispose() {
    if (closed) return;
    closed = true;
    unawaited(window?.close());
    window = null;
    super.dispose();
  }
}

/// Access-order LRU. Background events deliberately do not promote entries.
class ConversationMessageCache {
  ConversationMessageCache({
    this.capacity = 8,
    this.maxIdle = const Duration(minutes: 15),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       assert(capacity > 0);

  final int capacity;
  final Duration maxIdle;
  final DateTime Function() _now;
  final _entries = <String, ConversationMessageSource>{};
  Timer? _sweepTimer;

  ConversationMessageSource acquire(ConversationSummary conversation, Object scope) {
    prune();
    final key = _routingKey(conversation);
    var source = _entries.remove(key);
    if (source != null && (source.scope != scope || source.closed)) {
      source.dispose();
      source = null;
    }
    source ??= ConversationMessageSource(ConversationDetail(summary: conversation), scope, _now());
    source.lastAccess = _now();
    source.readers++;
    _entries[key] = source;
    _sweepTimer ??= Timer.periodic(const Duration(minutes: 1), (_) => prune());
    prune();
    return source;
  }

  void release(ConversationMessageSource source) {
    if (source.closed) return;
    if (source.readers > 0) source.readers--;
    source.lastAccess = _now();
    final key = _routingKey(source.detail.summary);
    if (identical(_entries[key], source)) {
      _entries.remove(key);
      _entries[key] = source;
    }
    prune();
  }

  void prune() {
    final now = _now();
    for (final key in _entries.keys.toList()) {
      final source = _entries[key]!;
      if (source.readers == 0 &&
          (now.difference(source.lastAccess) >= maxIdle || _entries.length > capacity)) {
        _entries.remove(key);
        source.dispose();
      }
    }
    if (_entries.isEmpty) {
      _sweepTimer?.cancel();
      _sweepTimer = null;
    }
  }

  void invalidateProvider(String providerId) {
    for (final key in _entries.keys.toList()) {
      if (_entries[key]!.detail.summary.providerId == providerId) {
        _entries.remove(key)!.dispose();
      }
    }
    prune();
  }

  void clear() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    for (final source in _entries.values) {
      source.dispose();
    }
    _entries.clear();
  }
}

String _routingKey(ConversationSummary conversation) =>
    conversation.resource?.key ?? '${conversation.providerId}\u0000${conversation.id}';
