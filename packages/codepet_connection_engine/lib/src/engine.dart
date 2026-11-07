import 'dart:async';
import 'dart:math' as math;

import 'budget.dart';
import 'contracts.dart';

/// Scene-independent owner. Async results are fenced by lifecycle and identity.
final class ConnectionEngine {
  ConnectionEngine({
    required this.handover,
    CandidateBudget? budget,
    this.policy = const ConnectionPolicy(),
    int Function()? nowMilliseconds,
    double Function()? random,
    this.onDiagnostic,
  }) : budget = budget ?? CandidateBudget() {
    policy.validate();
    _random = random ?? math.Random().nextDouble;
    final clock = Stopwatch()..start();
    _now = nowMilliseconds ?? () => clock.elapsedMilliseconds;
  }
  final ConnectionHandover handover;
  final CandidateBudget budget;
  final ConnectionPolicy policy;
  final void Function(String, Map<String, Object?>)? onDiagnostic;
  late final int Function() _now;
  late final double Function() _random;
  final _changes = StreamController<ConnectionSnapshot>.broadcast();
  final _entries = <ChannelKind, _Entry>{};
  final _retiring = <_Entry>{};
  ConnectionTarget? _target;
  _Entry? _active;
  bool _desired = false,
      _disposed = false,
      _disposing = false,
      _activating = false,
      _probing = false,
      _refreshAfterActivation = false;
  int _epoch = 0, _revision = 0, _lastUpgrade = -1000000, _probeFailures = 0;
  int _retryRound = 0;
  Future<void>? _disposal;
  String? _error;
  ConnectionHealth _health = ConnectionHealth.unknown;
  ConnectionPhase _phase = ConnectionPhase.stopped;
  Timer? _retry, _sample, _probeTimer, _healthRetry;
  Cancellation? _probeCancellation;
  Stream<ConnectionSnapshot> get changes => _changes.stream;
  int get retiringCount => _retiring.length;
  PreparedConnection? get active => _active?.connection;
  ConnectionSnapshot get snapshot => ConnectionSnapshot(
    revision: _revision,
    phase: _phase,
    health: _health,
    connectionId: active?.id,
    channel: active?.channel,
    traffic: active?.traffic,
    optimizing: _active != null && _entries.isNotEmpty,
    errorCode: _error,
    candidateCount: _entries.length,
  );

  void reconcile(ConnectionTarget target) {
    if (_disposed || _disposing) throw StateError('ConnectionEngine disposed');
    final old = _target;
    if (old != null && old.id != target.id) {
      throw ArgumentError('Target identity changed');
    }
    final authChanged =
        old != null &&
        old.authorizationRevision != target.authorizationRevision;
    final environmentChanged =
        old != null && old.environmentRevision != target.environmentRevision;
    if (_phase == ConnectionPhase.blocked && !authChanged) return;
    _target = target;
    _desired = true;
    if (authChanged) {
      _epoch++;
      _cancelCandidates();
      _dropActive();
    } else if (environmentChanged) {
      // Resolve an in-flight authoritative activation before reevaluating hints.
      if (!_activating) {
        _cancelCandidates();
      } else {
        _refreshAfterActivation = true;
      }
      unawaited(_probe());
    }
    if (authChanged ||
        environmentChanged ||
        old == null ||
        _phase == ConnectionPhase.stopped) {
      _retry?.cancel();
      _retry = null;
      _error = null;
      _retryRound = 0;
      _phase = _active == null
          ? ConnectionPhase.selecting
          : ConnectionPhase.online;
      _launch();
    } else if (_active == null && _entries.isEmpty && _retry == null) {
      _launch();
    }
    _publish();
  }

  void _launch() {
    if (!_desired || _disposed || _phase == ConnectionPhase.blocked) return;
    if (_active != null && !_target!.optimize) return;
    for (final route in _target!.routes) {
      if (_active != null && route.kind.index >= _active!.route.kind.index) {
        continue;
      }
      if (_entries.containsKey(route.kind)) continue;
      if (_retiring.length >= 4) {
        _error = 'cleanup_budget_exhausted';
        break;
      }
      final entry = _Entry(route, _epoch);
      _entries[route.kind] = entry;
      unawaited(_open(entry));
    }
    if (_active == null) {
      _phase = _entries.isEmpty
          ? ConnectionPhase.waiting
          : ConnectionPhase.selecting;
    }
    _schedule();
  }

  Future<void> _open(_Entry entry) async {
    entry.opening = true;
    entry.deadline = Timer(
      entry.route.timeout,
      () => _fail(entry, const ConnectionFailure('candidate_timeout')),
    );
    try {
      entry.lease = await budget.acquire(
        entry.cancel,
        priority: _active == null ? 0 : 1,
      );
      entry.cancel.check();
      entry.opening = true;
      final connection = await entry.route.open(entry.cancel);
      entry.opening = false;
      entry.connection = connection;
      if (connection.channel != entry.route.kind) {
        throw const ConnectionFailure('candidate_channel_mismatch');
      }
      if (!_valid(entry)) {
        _cleanup(entry);
        return;
      }
      entry.subscription = connection.healthChanges.listen(
        (health) {
          if (entry.retired) return;
          if (identical(entry, _active)) {
            _health = health;
            if (health == ConnectionHealth.unusable) {
              _fail(entry, const ConnectionFailure('channel_unusable'));
            } else if (health == ConnectionHealth.suspect) {
              unawaited(_probe());
            }
            _publish();
          } else if (health == ConnectionHealth.unusable) {
            _fail(entry, const ConnectionFailure('candidate_unusable'));
          }
        },
        onError: (Object error) => _fail(entry, error),
        onDone: () => _fail(entry, const ConnectionFailure('channel_closed')),
      );
      entry.deadline?.cancel();
      entry.readyAt = _now();
      // Batch same-turn readiness so preference wins over callback ordering.
      scheduleMicrotask(_choose);
    } catch (error) {
      entry.opening = false;
      if (error is ConnectionFailure && error.unreleasedResources) {
        entry.cleaning =
            true; // Quarantine even when open never returned a handle.
        _diagnostic('open_cleanup_failed_quarantined', {
          'channel': entry.route.kind.name,
        });
      }
      if (!entry.retired) {
        _fail(entry, error);
      } else {
        _cleanup(entry);
      }
    }
  }

  bool _valid(_Entry entry) =>
      !entry.retired && _desired && !_disposed && entry.epoch == _epoch;
  void _choose() {
    if (_activating ||
        !_desired ||
        _disposed ||
        (_active != null && !_target!.optimize)) {
      return;
    }
    final ready =
        _entries.values.where((e) => _valid(e) && e.readyAt != null).toList()
          ..sort((a, b) => a.route.kind.index.compareTo(b.route.kind.index));
    if (ready.isEmpty) return;
    final next = ready.first;
    if (_active != null) {
      final wait =
          [
            next.readyAt! + policy.stability.inMilliseconds,
            _lastUpgrade + policy.upgradeCooldown.inMilliseconds,
          ].reduce((a, b) => a > b ? a : b) -
          _now();
      if (wait > 0) {
        next.stability?.cancel();
        next.stability = Timer(Duration(milliseconds: wait), _choose);
        return;
      }
    }
    unawaited(_activate(next));
  }

  Future<void> _activate(_Entry next) async {
    _activating = true;
    final previous = _active;
    try {
      final ok = await next.cancel.bind(
        next.connection!.probe(next.cancel),
        timeout: policy.probeTimeout,
      );
      if (!_valid(next)) return;
      if (!ok) throw const ConnectionFailure('candidate_probe_failed');
      final committed = await next.cancel.bind(
        handover.activate(previous?.connection, next.connection!, next.cancel),
        timeout: policy.activationTimeout,
        timeoutFailure: const ConnectionFailure(
          'activation_outcome_unknown',
          permanent: true,
        ),
      );
      if (!_valid(next)) return;
      if (!committed) {
        _retire(next);
        return;
      }
      _entries.remove(next.route.kind);
      _active = next;
      next.lease?.release();
      _probeFailures = 0;
      _retryRound = 0;
      _health = ConnectionHealth.healthy;
      _phase = ConnectionPhase.online;
      _error = null;
      if (previous != null) {
        _lastUpgrade = _now();
        _retire(previous);
      }
      for (final entry in _entries.values.toList()) {
        if (entry.route.kind.index >= next.route.kind.index) _retire(entry);
      }
      _sample ??= Timer.periodic(policy.sampleInterval, (_) => _publish());
      _probeTimer ??= Timer.periodic(
        policy.probeInterval,
        (_) => unawaited(_probe()),
      );
      _diagnostic('active', {
        'channel': next.connection!.channel.name,
        'connectionId': next.connection!.id,
      });
      _publish();
    } catch (error) {
      if (_valid(next)) _fail(next, error);
    } finally {
      _activating = false;
      if (_refreshAfterActivation) {
        _refreshAfterActivation = false;
        _cancelCandidates();
        _launch();
      }
      _choose();
      _schedule();
    }
  }

  Future<void> _probe() async {
    final entry = _active;
    if (entry == null || _probing || !_desired || _disposed) return;
    _probing = true;
    final cancellation = _probeCancellation = Cancellation();
    try {
      final ok = await cancellation.bind(
        entry.connection!.probe(cancellation),
        timeout: policy.probeTimeout,
      );
      if (!identical(entry, _active) || !_valid(entry)) return;
      if (ok) {
        _probeFailures = 0;
        _health = ConnectionHealth.healthy;
      } else {
        _probeFailed(entry);
      }
    } catch (error) {
      if (identical(entry, _active) && _valid(entry)) {
        if (error is ConnectionFailure && error.permanent) {
          _fail(entry, error);
        } else {
          _probeFailed(entry);
        }
      }
    } finally {
      cancellation.cancel();
      if (identical(_probeCancellation, cancellation)) {
        _probeCancellation = null;
      }
      _probing = false;
      _publish();
    }
  }

  void _probeFailed(_Entry entry) {
    _health = ConnectionHealth.suspect;
    if (++_probeFailures >= policy.maxProbeFailures) {
      _fail(entry, const ConnectionFailure('health_timeout'));
    } else {
      _healthRetry ??= Timer(const Duration(seconds: 1), () {
        _healthRetry = null;
        unawaited(_probe());
      });
    }
  }

  void _fail(_Entry entry, Object error) {
    if (entry.retired) return;
    final fatal = error is ConnectionFailure && error.permanent;
    _error = error is ConnectionFailure ? error.code : 'candidate_failed';
    _diagnostic('failure', {'channel': entry.route.kind.name, 'code': _error});
    final wasActive = identical(_active, entry);
    if (wasActive) {
      _active = null;
      _health = ConnectionHealth.unusable;
    }
    _retire(entry);
    if (fatal) {
      _phase = ConnectionPhase.blocked;
      _cancelCandidates();
      _dropActive();
      _stopTimers();
    } else if (_desired && !_disposed) {
      if (wasActive) {
        _phase = ConnectionPhase.selecting;
        _launch();
      }
      _choose();
      _schedule();
    }
    _publish();
  }

  void _schedule() {
    if (!_desired ||
        _disposed ||
        _phase == ConnectionPhase.blocked ||
        _entries.isNotEmpty ||
        _activating) {
      return;
    }
    if ((_active != null && !_target!.optimize) ||
        _active?.route.kind == ChannelKind.lan ||
        _target!.routes.isEmpty) {
      return;
    }
    if (_active == null) _phase = ConnectionPhase.waiting;
    if (_retry != null) return;
    final base = _active == null ? policy.retry : policy.recheck;
    final delay = Duration(
      milliseconds: math.min(
        (base.inMilliseconds *
                (1 << math.min(_retryRound++, 5)) *
                (0.8 + _random().clamp(0.0, 1.0) * 0.4))
            .round(),
        policy.maxRetry.inMilliseconds,
      ),
    );
    _retry = Timer(delay, () {
      _retry = null;
      _launch();
      _publish();
    });
  }

  void _retire(_Entry entry) {
    if (entry.retired) return;
    entry.retired = true;
    if (identical(_entries[entry.route.kind], entry)) {
      _entries.remove(entry.route.kind);
    }
    entry.cancel.cancel();
    entry.deadline?.cancel();
    entry.stability?.cancel();
    _retiring.add(entry);
    _cleanup(entry);
  }

  void _cleanup(_Entry entry) {
    if (entry.opening || entry.cleaning) return;
    entry.cleaning = true;
    unawaited(() async {
      try {
        await entry.subscription?.cancel();
      } catch (_) {
        // A broken observer must not prevent closing the native resource.
        _diagnostic('subscription_cleanup_failed', {
          'channel': entry.route.kind.name,
        });
      }
      try {
        await entry.connection?.close();
      } catch (_) {
        // Its native outcome is unknown. Quarantine the slot; releasing it
        // would let repeated close failures create unbounded native resources.
        _diagnostic('cleanup_failed_quarantined', {
          'channel': entry.route.kind.name,
        });
        return;
      }
      entry.lease?.release();
      _retiring.remove(entry);
      if (!entry.cleaned.isCompleted) entry.cleaned.complete();
    }());
  }

  void _dropActive() {
    final previous = _active;
    _active = null;
    _probeCancellation?.cancel();
    if (previous != null) _retire(previous);
    _health = ConnectionHealth.unknown;
  }

  void _cancelCandidates() {
    for (final e in _entries.values.toList()) {
      _retire(e);
    }
  }

  void _stopTimers() {
    _retry?.cancel();
    _retry = null;
    _healthRetry?.cancel();
    _healthRetry = null;
    _sample?.cancel();
    _sample = null;
    _probeTimer?.cancel();
    _probeTimer = null;
    _probeCancellation?.cancel();
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    _desired = false;
    _epoch++;
    _stopTimers();
    _cancelCandidates();
    _dropActive();
    _phase = ConnectionPhase.stopped;
    _error = null;
    _publish();
    await Future.wait(_retiring.map((e) => e.cleaned.future))
        .timeout(policy.cleanupTimeout, onTimeout: () => <void>[]);
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    // Fence synchronously: waiting for cleanup must not allow resurrection.
    _disposing = true;
    return _disposal = () async {
      await disconnect();
      _disposed = true;
      _phase = ConnectionPhase.disposed;
      await _changes.close();
    }();
  }

  void _publish() {
    if (!_disposed) {
      _revision++;
      _changes.add(snapshot);
    }
  }

  void _diagnostic(String event, Map<String, Object?> fields) {
    try {
      onDiagnostic?.call(event, {
        'target': _target?.id,
        'epoch': _epoch,
        ...fields,
      });
    } catch (_) {}
  }
}

final class _Entry {
  _Entry(this.route, this.epoch);
  final CandidateRoute route;
  final int epoch;
  final cancel = Cancellation();
  final cleaned = Completer<void>();
  BudgetLease? lease;
  PreparedConnection? connection;
  StreamSubscription<ConnectionHealth>? subscription;
  Timer? deadline, stability;
  int? readyAt;
  bool retired = false, opening = false, cleaning = false;
}
