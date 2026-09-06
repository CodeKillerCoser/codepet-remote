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
    final next = detail.apply(event);
    if (identical(next, detail)) return;
    detail = next;
    lastEvent = incoming;
    notifyApplicationListeners();
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
