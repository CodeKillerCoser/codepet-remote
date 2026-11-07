import 'dart:async';

import 'traffic.dart';

enum ChannelKind { lan, ipv6Direct, ipv4Direct, relay }

enum ConnectionPhase { stopped, selecting, online, waiting, blocked, disposed }

enum ConnectionHealth { unknown, healthy, suspect, unusable }

final class ConnectionFailure implements Exception {
  const ConnectionFailure(
    this.code, {
    this.permanent = false,
    this.unreleasedResources = false,
  });
  final String code;
  final bool permanent;

  /// open failed before returning a handle, and native disposal is unconfirmed.
  final bool unreleasedResources;
  @override
  String toString() => code;
}

/// Cancellation is explicit and must be observed before side effects/activation.
final class Cancellation {
  final _done = Completer<void>();
  bool get isCancelled => _done.isCompleted;
  Future<void> get whenCancelled => _done.future;
  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }

  /// Bounds the wait, cancels its timer on completion/cancellation, and consumes
  /// late errors. The adapter still owns cancellation of the underlying IO.
  Future<T> bind<T>(
    Future<T> operation, {
    required Duration timeout,
    ConnectionFailure timeoutFailure = const ConnectionFailure(
      'operation_timeout',
    ),
  }) {
    final result = Completer<T>();
    final timer = Timer(timeout, () {
      if (!result.isCompleted) result.completeError(timeoutFailure);
    });
    operation.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!result.isCompleted) result.completeError(error, stack);
      },
    );
    whenCancelled.then((_) {
      if (!result.isCompleted) {
        result.completeError(const ConnectionFailure('cancelled'));
      }
    });
    return result.future.whenComplete(timer.cancel);
  }

  void check() {
    if (isCancelled) throw const ConnectionFailure('cancelled');
  }
}

/// Returned only after peer identity and preparation have succeeded.
/// No business events/requests may be delivered before Handover.activate.
abstract interface class PreparedConnection {
  String get id;
  ChannelKind get channel;
  Stream<ConnectionHealth> get healthChanges;
  TrafficSnapshot get traffic;
  Future<bool> probe(Cancellation cancellation);
  Future<void> close();
}

final class CandidateRoute {
  const CandidateRoute({
    required this.kind,
    required this.open,
    this.timeout = const Duration(seconds: 55),
  });
  final ChannelKind kind;
  final Future<PreparedConnection> Function(Cancellation cancellation) open;
  final Duration timeout;
}

/// Adapter owns the business drain barrier and authoritative peer activation.
/// Return false only if the previous connection is STILL authoritative.
/// Never return/throw an ambiguous commit: resolve it with the peer first, or
/// throw a permanent failure to fence both connections and require intervention.
abstract interface class ConnectionHandover {
  Future<bool> activate(
    PreparedConnection? previous,
    PreparedConnection next,
    Cancellation cancellation,
  );
}

final class ConnectionTarget {
  ConnectionTarget({
    required this.id,
    required this.authorizationRevision,
    required this.environmentRevision,
    this.optimize = true,
    required List<CandidateRoute> routes,
  }) : routes = List.unmodifiable(routes) {
    if (routes.map((r) => r.kind).toSet().length != routes.length) {
      throw ArgumentError('At most one candidate per channel family');
    }
  }
  final bool optimize;
  final String id;
  final int authorizationRevision, environmentRevision;
  final List<CandidateRoute> routes;
}

final class ConnectionPolicy {
  const ConnectionPolicy({
    this.stability = const Duration(seconds: 2),
    this.upgradeCooldown = const Duration(seconds: 15),
    this.retry = const Duration(seconds: 2),
    this.maxRetry = const Duration(seconds: 60),
    this.activationTimeout = const Duration(seconds: 10),
    this.recheck = const Duration(seconds: 30),
    this.probeInterval = const Duration(seconds: 20),
    this.probeTimeout = const Duration(seconds: 5),
    this.sampleInterval = const Duration(seconds: 1),
    this.cleanupTimeout = const Duration(seconds: 3),
    this.maxProbeFailures = 2,
  });
  final Duration stability,
      upgradeCooldown,
      retry,
      maxRetry,
      activationTimeout,
      recheck,
      probeInterval,
      probeTimeout,
      sampleInterval,
      cleanupTimeout;
  final int maxProbeFailures;
  void validate() {
    for (final value in [
      retry,
      maxRetry,
      activationTimeout,
      recheck,
      probeInterval,
      probeTimeout,
      sampleInterval,
      cleanupTimeout,
    ]) {
      if (value <= Duration.zero) {
        throw ArgumentError('Durations must be positive');
      }
    }
    if (stability.isNegative ||
        upgradeCooldown.isNegative ||
        maxProbeFailures < 1) {
      throw ArgumentError('Invalid stability/health policy');
    }
  }
}

final class ConnectionSnapshot {
  const ConnectionSnapshot({
    required this.revision,
    required this.phase,
    required this.health,
    this.connectionId,
    this.channel,
    this.traffic,
    this.optimizing = false,
    this.errorCode,
    this.candidateCount = 0,
  });
  final int revision;
  final ConnectionPhase phase;
  final ConnectionHealth health;
  final String? connectionId, errorCode;
  final ChannelKind? channel;
  final TrafficSnapshot? traffic;
  final bool optimizing;
  final int candidateCount;
}
