import 'dart:async';
import 'dart:convert';

import '../../core/domain/models.dart';
import '../../core/domain/notification.dart';

abstract interface class LiveUpdates {
  /// False means the user dismissed this activity. Never automatically re-pin it.
  Future<bool> showActivity(LiveActivity activity);
  Future<void> endActivity();
  Future<void> beginActivity(String key);
}

class LiveActivity {
  const LiveActivity(this.target, this.title, this.body, this.preview);
  final NotificationTarget target;
  final String title;
  final String body;
  final bool preview;
  String get key => jsonEncode([target.conversationKey, target.turnId]);
}

/// One explicitly selected turn, never an ambient feed of other users' tasks.
/// No persisted follow: after process death the user must opt in again.
class LiveUpdateCoordinator {
  LiveUpdateCoordinator(this.platform, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final LiveUpdates platform;
  final DateTime Function() now;
  NotificationTarget? target;
  DateTime? _version;
  DateTime? _lastSeen;
  final Set<String> _closedRequests = {};
  String? _requestId;
  String _headline = '任务运行中';
  String? _summary;
  bool preview = false;
  Future<void> _queue = Future.value();
  Timer? _timer;

  Future<void> _serial(Future<void> Function() work) {
    final next = _queue.then((_) => work());
    _queue = next.catchError((Object _) {});
    return next;
  }

  bool follows(NotificationTarget value) =>
      target?.conversationKey == value.conversationKey;

  Future<void> follow(
    NotificationTarget value,
    TurnTask turn, {
    required bool preview,
    bool waitingForInput = false,
  }) => _serial(() async {
    await _end();
    if (turn.status.isTerminal) return;
    target = NotificationTarget(
      deviceId: value.deviceId,
      providerId: value.providerId,
      conversationId: value.conversationId,
      turnId: turn.id,
    );
    _requestId = value.requestId;
    this.preview = preview;
    _version = turn.updatedAt;
    _lastSeen = now();
    _headline = waitingForInput
        ? '需要补充信息'
        : turn.status == TurnStatus.waitingApproval
        ? '需要授权'
        : turn.status == TurnStatus.queued
        ? '任务排队中'
        : '任务运行中';
    _summary = turn.displaySummary;
    await platform.beginActivity(_activity().key);
    await _render();
    if (target == null) return;
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      unawaited(expire().catchError((Object _) {}));
    });
  });

  Future<void> stop() => _serial(_end);
  Future<void> _end() async {
    target = null;
    _timer?.cancel();
    _timer = null;
    _version = null;
    _requestId = null;
    _closedRequests.clear();
    await platform.endActivity();
  }

  Future<void> expire() => _serial(() async {
    // No heartbeat/progress proof: do not leave a stale ongoing activity forever.
    if (_lastSeen != null &&
        now().difference(_lastSeen!) >= const Duration(minutes: 3)) {
      await _end();
    }
  });

  Future<void> setPreview(bool enabled) => _serial(() async {
    preview = enabled;
    await _render();
  });

  Future<void> updateTurn(NotificationTarget value, TurnTask turn) =>
      _serial(() async {
        if (!follows(value) || target?.turnId != turn.id) return;
        final at = turn.completedAt ?? turn.updatedAt;
        if (_version != null && at.isBefore(_version!)) return;
        if (turn.status.isTerminal) {
          await _end();
          return;
        }
        if (_version == null || at.isAfter(_version!)) _lastSeen = now();
        _version = at;
        if (turn.status != TurnStatus.waitingApproval) {
          if (_requestId != null) _closedRequests.add(_requestId!);
          _requestId = null;
        }
        _headline = switch (turn.status) {
          TurnStatus.queued => '任务排队中',
          TurnStatus.waitingApproval => '需要授权',
          _ => '任务运行中',
        };
        _summary = turn.displaySummary;
        await _render();
      });

  Future<void> conversation(
    NotificationTarget value,
    ConversationSummary conversation,
  ) => _serial(() async {
    if (!follows(value)) return;
    if (_version != null && conversation.updatedAt.isBefore(_version!)) return;
    if (conversation.activeTurn?.id != target?.turnId) {
      await _end();
      return;
    }
    _version = conversation.updatedAt;
    _lastSeen = now();
    _headline = switch (conversation.status) {
      ConversationStatus.waitingApproval => '需要授权',
      ConversationStatus.waitingUserInput => '需要补充信息',
      _ => '任务运行中',
    };
    if (conversation.status != ConversationStatus.waitingApproval) {
      if (_requestId != null) _closedRequests.add(_requestId!);
      _requestId = null;
      _summary = conversation.activeTurn?.displaySummary;
    }
    if (conversation.activeTurn?.status.isTerminal == true) {
      await _end();
      return;
    }
    await _render();
  });

  Future<void> request(InterventionRequest request) => _serial(() async {
    if (!follows(request.target) ||
        (request.target.turnId != null &&
            request.target.turnId != target?.turnId)) {
      return;
    }
    final id = request.target.requestId;
    if (request.status != InterventionStatus.pending) {
      if (id != null) _closedRequests.add(id);
      if (_requestId != id) return;
      _requestId = null;
      _headline = '状态同步中';
      _summary = null;
    } else {
      if ((id != null && _closedRequests.contains(id)) ||
          (_version != null && request.at.isBefore(_version!))) {
        return;
      }
      _version = request.at;
      _requestId = id;
      _headline = request.kind == InterventionKind.approval ? '需要授权' : '需要补充信息';
      _summary = request.summary;
    }
    _lastSeen = now();
    await _render();
  });

  LiveActivity _activity() {
    final current = target!;
    return LiveActivity(
      NotificationTarget(
        deviceId: current.deviceId,
        providerId: current.providerId,
        conversationId: current.conversationId,
        turnId: current.turnId,
        requestId: _requestId,
      ),
      _headline,
      preview && _summary?.isNotEmpty == true
          ? String.fromCharCodes(
              _summary!.replaceAll(RegExp(r'\s+'), ' ').runes.take(120),
            )
          : '打开 CodePet Remote 查看最新任务状态',
      preview,
    );
  }

  Future<void> _render() async {
    if (target == null) return;
    if (!await platform.showActivity(_activity())) await _end();
  }

  void dispose() {
    _timer?.cancel();
    unawaited(stop().catchError((Object _) {}));
  }
}
