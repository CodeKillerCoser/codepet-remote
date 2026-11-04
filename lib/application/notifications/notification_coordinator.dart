import 'dart:convert';

import '../../core/domain/models.dart';
import '../../core/domain/notification.dart';
import '../ports/application_log.dart';
import '../ports/system_notifications.dart';

/// Consumes fenced, device-wide events, independently of visited pages/caches.
/// The durable ledger stores routing identities and delivery state, never bodies.
class NotificationCoordinator {
  NotificationCoordinator({
    required this.system,
    required this.store,
    this.logger = const NoopApplicationLog(),
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;
  final SystemNotifications system;
  final NotificationStore store;
  final ApplicationLog logger;
  final DateTime Function() now;
  NotificationPreferences preferences = const NotificationPreferences();
  bool foreground = true;
  String? visibleConversation;
  final Map<String, Map<String, dynamic>> _ledger = {};
  final Map<int, int> _presentationHashes = {};
  Future<void> _pending = Future.value();
  bool _disposed = false;
  int _nextId = 100;

  Future<void> initialize() async {
    preferences = await store.loadPreferences();
    final saved = await store.loadLedger();
    _nextId = (saved['nextId'] as int?) ?? 100;
    final entries = saved['entries'];
    if (entries is Map) {
      for (final entry in entries.entries) {
        if (entry.value is Map) {
          _ledger[entry.key as String] = Map<String, dynamic>.from(
            entry.value as Map,
          );
        }
      }
    }
  }

  Future<void> _enqueue(Future<void> Function() work) {
    _pending = _pending
        .then((_) async {
          if (!_disposed) await work();
        })
        .catchError((Object error, StackTrace stack) {
          logger.warning(
            'Notification operation failed',
            error: error,
            stackTrace: stack,
          );
        });
    return _pending;
  }

  Future<void> get settled => _pending;

  Future<void> updatePreferences(NotificationPreferences value) async {
    await store.savePreferences(value);
    preferences = value;
    await _enqueue(() async {
      for (final entry in _ledger.values) {
        if ((!value.outcomes && entry['kind'] == 'outcome') ||
            (!value.interventions && entry['kind'] == 'intervention') ||
            (!value.preview && entry['preview'] == true)) {
          await _cancel(entry['id'] as int);
        }
      }
    });
  }

  Future<void> forgetDevice(String deviceId) => _enqueue(() async {
    for (final key in _ledger.keys.toList()) {
      if (_ledger[key]!['deviceId'] == deviceId) {
        await _cancel(_ledger[key]!['id'] as int);
        _ledger.remove(key);
      }
    }
    await _save();
  });

  Future<void> acknowledge(NotificationTarget target) => _enqueue(() async {
    for (final entry in _ledger.values) {
      if (entry['conversationKey'] == target.conversationKey) {
        await _cancel(entry['id'] as int);
      }
    }
    // Viewing dismisses the notification, not the underlying intervention.
  });

  Future<void> snapshot(
    String deviceId,
    String deviceName,
    List<ConversationSummary> conversations,
  ) => _enqueue(() async {
    for (final conversation in conversations) {
      await _conversation(deviceId, deviceName, conversation);
      // Historical terminal turns are deliberately not turned into notices.
    }
    await _save();
  });

  Future<void> event(
    String deviceId,
    String deviceName,
    GatewayEvent event,
    ConversationSummary? conversation,
  ) => _enqueue(() async {
    if (event is TurnUpsertedEvent) {
      final turn = event.turn;
      if (!turn.status.isTerminal) return;
      final target = NotificationTarget(
        deviceId: deviceId,
        providerId: turn.conversationResource?.providerId ?? turn.providerId,
        conversationId:
            turn.conversationResource?.nativeResourceId ??
            _nativeConversationId(turn.conversationId, turn.providerId),
        turnId: turn.id,
      );
      // Protocol timestamps are optional. A missing updatedAt can be mapped
      // to startedAt/epoch; do not discard a fresh completion of a long task.
      final at =
          turn.completedAt ??
          (turn.updatedAt.millisecondsSinceEpoch == 0 ||
                  turn.updatedAt == turn.startedAt
              ? now()
              : turn.updatedAt);
      await _resolveConversation(target, at, turnId: turn.id);
      final outcome = TaskOutcome(target: target, status: turn.status, at: at);
      await _outcome(
        outcome,
        deviceName,
        conversation?.title,
        turn.displaySummary,
      );
    } else if (event is ApprovalChangedEvent) {
      final approval = event.approval;
      final resource = approval.resource;
      if (resource == null) return;
      final target = NotificationTarget(
        deviceId: deviceId,
        providerId: resource.providerId,
        conversationId:
            conversation?.resource?.nativeResourceId ??
            _nativeConversationId(event.conversationId, resource.providerId),
        turnId: approval.turnId,
        requestId: approval.id,
      );
      final request = InterventionRequest(
        target: target,
        kind: InterventionKind.approval,
        status: switch (approval.approvalStatus) {
          'pending' => InterventionStatus.pending,
          'cancelled' => InterventionStatus.cancelled,
          'expired' => InterventionStatus.expired,
          _ => InterventionStatus.resolved,
        },
        at: approval.createdAt,
        summary: approval.approvalDescription ?? approval.title,
      );
      await _request(request, deviceName, conversation?.title);
    } else if (event is ConversationUpsertedEvent) {
      await _conversation(deviceId, deviceName, event.conversation);
    }
    await _save();
  });

  String _nativeConversationId(String id, String providerId) {
    final prefix = '$providerId\u0000';
    return id.startsWith(prefix) ? id.substring(prefix.length) : id;
  }

  Future<void> _conversation(
    String deviceId,
    String deviceName,
    ConversationSummary value,
  ) async {
    final target = NotificationTarget(
      deviceId: deviceId,
      providerId: value.resource?.providerId ?? value.providerId,
      conversationId: value.resource?.nativeResourceId ?? value.id,
      turnId: value.activeTurn?.id,
    );
    if (value.status == ConversationStatus.waitingUserInput ||
        value.status == ConversationStatus.waitingApproval) {
      final approval = value.status == ConversationStatus.waitingApproval;
      // Do not duplicate a structured approval with a summary-only placeholder.
      if (approval &&
          _ledger.values.any(
            (e) =>
                e['conversationKey'] == target.conversationKey &&
                e['requestId'] != null &&
                e['state'] == 'pending',
          )) {
        return;
      }
      await _request(
        InterventionRequest(
          target: target,
          kind: approval ? InterventionKind.approval : InterventionKind.input,
          status: InterventionStatus.pending,
          at: value.updatedAt,
        ),
        deviceName,
        value.title,
      );
    } else {
      await _resolveConversation(target, value.updatedAt);
    }
  }

  String _key(NotificationTarget target, String kind, String identity) =>
      jsonEncode([
        target.deviceId,
        target.providerId,
        target.conversationId,
        kind,
        identity,
      ]);

  Map<String, dynamic> _entry(NotificationTarget target, NoticeKind kind) => {
    'id': _nextId++,
    'deviceId': target.deviceId,
    'conversationKey': target.conversationKey,
    'turnId': target.turnId,
    'requestId': target.requestId,
    'kind': kind.name,
    'seenAt': now().millisecondsSinceEpoch,
    'announced': false,
  };

  Future<void> _outcome(
    TaskOutcome outcome,
    String deviceName,
    String? title,
    String? summary,
  ) async {
    final key = _key(outcome.target, 'outcome', outcome.target.turnId!);
    final existing = _ledger[key];
    if (existing?['announced'] == true) return;
    final entry = existing ?? _entry(outcome.target, NoticeKind.outcome);
    _ledger[key] = entry;
    entry['state'] = outcome.status.name;
    entry['version'] = outcome.at.millisecondsSinceEpoch;
    // Replay beyond a short delivery window is history, not a fresh completion.
    if (outcome.status == TurnStatus.interrupted ||
        now().difference(outcome.at) > const Duration(minutes: 10)) {
      entry['announced'] = true;
      return;
    }
    final headline = outcome.status == TurnStatus.completed
        ? '任务已完成'
        : '任务执行失败';
    await _display(
      entry,
      outcome.target,
      NoticeKind.outcome,
      headline,
      deviceName,
      title,
      summary,
    );
  }

  Future<void> _request(
    InterventionRequest request,
    String deviceName,
    String? title,
  ) async {
    if (request.status == InterventionStatus.pending &&
        request.target.turnId != null &&
        _ledger.containsKey(
          _key(request.target, 'outcome', request.target.turnId!),
        )) {
      return;
    }
    final identity = request.target.requestId ?? 'summary-${request.kind.name}';
    final key = _key(request.target, 'intervention', identity);
    final previous = _ledger[key];
    final version = request.at.millisecondsSinceEpoch;
    // Resolved approvals are tombstones: a replayed pending event cannot revive them.
    if (request.status == InterventionStatus.pending &&
        previous != null &&
        (version < (previous['version'] as int? ?? 0) ||
            (request.target.requestId != null &&
                previous['state'] != 'pending'))) {
      return;
    }
    final entry = previous ?? _entry(request.target, NoticeKind.intervention);
    _ledger[key] = entry;
    if (request.status != InterventionStatus.pending) {
      entry['state'] = request.status.name;
      entry['version'] = version;
      await _cancel(entry['id'] as int);
      return;
    }
    if (previous != null && previous['state'] != 'pending') {
      if (version <= (previous['version'] as int? ?? 0)) return;
      entry['announced'] = false;
    }
    entry['state'] = 'pending';
    entry['version'] = version;
    entry['turnId'] = request.target.turnId;
    if (request.target.requestId != null) {
      final genericKey = _key(
        request.target,
        'intervention',
        'summary-approval',
      );
      final generic = _ledger[genericKey];
      if (generic != null && generic['state'] == 'pending') {
        // Replace the generic notification without a second alert.
        entry['silent'] = generic['announced'] == true;
        generic['state'] = 'resolved';
        await _cancel(generic['id'] as int);
      }
    }
    final headline = switch (request.kind) {
      InterventionKind.approval => '需要授权',
      InterventionKind.input => '需要补充信息',
      InterventionKind.decision => '需要你确认',
    };
    await _display(
      entry,
      request.target,
      NoticeKind.intervention,
      headline,
      deviceName,
      title,
      request.summary,
    );
  }

  Future<void> _resolveConversation(
    NotificationTarget target,
    DateTime at, {
    String? turnId,
  }) async {
    for (final entry in _ledger.values) {
      if (entry['kind'] != 'intervention' ||
          entry['state'] != 'pending' ||
          entry['conversationKey'] != target.conversationKey ||
          (turnId != null &&
              entry['turnId'] != null &&
              entry['turnId'] != turnId) ||
          (entry['version'] as int? ?? 0) > at.millisecondsSinceEpoch) {
        continue;
      }
      entry['state'] = 'resolved';
      entry['version'] = at.millisecondsSinceEpoch;
      await _cancel(entry['id'] as int);
    }
  }

  Future<void> _display(
    Map<String, dynamic> entry,
    NotificationTarget target,
    NoticeKind kind,
    String headline,
    String deviceName,
    String? title,
    String? summary,
  ) async {
    final id = entry['id'] as int;
    final presentationHash = Object.hash(
      headline,
      deviceName,
      title,
      summary,
      preferences.preview,
    );
    final updating =
        entry['announced'] == true &&
        _presentationHashes.containsKey(id) &&
        _presentationHashes[id] != presentationHash;
    if (entry['announced'] == true && !updating) return;
    final enabled = kind == NoticeKind.outcome
        ? preferences.outcomes
        : preferences.interventions;
    if (!enabled ||
        (foreground && visibleConversation == target.conversationKey)) {
      entry['announced'] = true;
      _presentationHashes.remove(id);
      return;
    }
    if (!await system.isAllowed()) return;
    final preview = preferences.preview;
    String brief(String value) => String.fromCharCodes(
      value.replaceAll(RegExp(r'\s+'), ' ').trim().runes.take(120),
    );
    await system.show(
      RemoteNotice(
        id: entry['id'] as int,
        target: target,
        kind: kind,
        title: preview && title != null
            ? '$headline · ${brief(title)}'
            : headline,
        body: preview
            ? [
                brief(deviceName),
                if (summary?.isNotEmpty == true) brief(summary!),
              ].join(' · ')
            : kind == NoticeKind.intervention
            ? '打开 CodePet Remote 查看并处理'
            : '打开 CodePet Remote 查看任务结果',
        preview: preview,
        silent: updating || entry['silent'] == true,
      ),
    );
    entry['announced'] = true;
    entry['preview'] = preview;
    _presentationHashes[id] = presentationHash;
  }

  Future<void> _cancel(int id) async {
    _presentationHashes.remove(id);
    await system.cancel(id);
  }

  Future<void> _save() async {
    final cutoff = now()
        .subtract(const Duration(days: 7))
        .millisecondsSinceEpoch;
    for (final key in _ledger.keys.toList()) {
      final entry = _ledger[key]!;
      if ((entry['seenAt'] as int? ?? 0) < cutoff) {
        await _cancel(entry['id'] as int);
        _ledger.remove(key);
      }
    }
    while (_ledger.length > 512) {
      final key = _ledger.keys.first;
      await _cancel(_ledger[key]!['id'] as int);
      _ledger.remove(key);
    }
    await store.saveLedger({'nextId': _nextId, 'entries': _ledger});
  }

  void dispose() {
    _disposed = true;
  }
}
