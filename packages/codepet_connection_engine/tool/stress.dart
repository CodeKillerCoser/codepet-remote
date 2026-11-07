import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:codepet_connection_engine/codepet_connection_engine.dart';

/// Standalone adapter load harness: no Flutter, server, account or socket.
/// Measures engine scheduling/cleanup, NOT network bandwidth or ICE latency.
Future<void> main(List<String> args) async {
  final cycles = args.isEmpty ? 10000 : int.parse(args[0]);
  final devices = args.length < 2 ? 16 : int.parse(args[1]);
  if (cycles < 1 || devices < 1 || devices > 256) {
    throw ArgumentError(
      'usage: dart run tool/stress.dart [cycles>0] [devices 1..256]',
    );
  }
  final budget = CandidateBudget(limit: 8);
  final bridges = List.generate(devices, (_) => _Handover());
  final engines = List.generate(
    devices,
    (i) => ConnectionEngine(
      handover: bridges[i],
      budget: budget,
      policy: const ConnectionPolicy(
        stability: Duration.zero,
        upgradeCooldown: Duration.zero,
      ),
    ),
  );
  final elapsed = Stopwatch()..start();
  final latencies = <int>[],
      recoveries = <int>[],
      upgrades = <int>[],
      cleanup = <int>[];
  var peakRss = ProcessInfo.currentRss;
  try {
    for (var base = 0; base < cycles; base += devices) {
      await Future.wait(
        List.generate(min(devices, cycles - base), (i) async {
          final engine = engines[i];
          final round = base + i;
          var minimum = round % 4;
          var opens = 0;
          final time = Stopwatch()..start();
          final ready = engine.changes.firstWhere(
            (s) => s.phase == ConnectionPhase.online,
          );
          final target = ConnectionTarget(
            id: 'device$i',
            authorizationRevision: 0,
            environmentRevision: round,
            routes: [
              for (final kind in ChannelKind.values)
                CandidateRoute(
                  kind: kind,
                  open: (cancel) async {
                    cancel.check();
                    if (kind.index < minimum) {
                      throw const ConnectionFailure('injected_unreachable');
                    }
                    final c = _Connection(
                      '$round-${kind.name}-${++opens}',
                      kind,
                    );
                    c.meter.record(sent: 1024, received: 8192);
                    return c;
                  },
                ),
            ],
          );
          for (var repeat = 0; repeat < 10; repeat++) {
            engine.reconcile(target);
          }
          await ready.timeout(const Duration(seconds: 5));
          latencies.add(time.elapsedMicroseconds);
          if (engine.active!.channel.index != round % 4) {
            throw StateError('wrong selected path');
          }
          if (engine.snapshot.traffic!.totalBytes != 9216) {
            throw StateError('mixed traffic');
          }
          if (round % 3 == 0 || (round % 3 == 1 && minimum > 0)) {
            final old = engine.active! as _Connection;
            final switched = engine.changes.firstWhere(
              (snapshot) =>
                  snapshot.phase == ConnectionPhase.online &&
                  snapshot.connectionId != old.id,
            );
            final switching = Stopwatch()..start();
            if (round % 3 == 0) {
              old._health.add(ConnectionHealth.unusable);
            } else {
              minimum = 0;
              engine.reconcile(
                ConnectionTarget(
                  id: target.id,
                  authorizationRevision: 0,
                  environmentRevision: round + 1,
                  routes: target.routes,
                ),
              );
            }
            await switched.timeout(const Duration(seconds: 5));
            (round % 3 == 0 ? recoveries : upgrades).add(
              switching.elapsedMicroseconds,
            );
            if (engine.active!.channel.index != minimum) {
              throw StateError('wrong switched path');
            }
          }
          final closing = Stopwatch()..start();
          await engine.disconnect();
          cleanup.add(closing.elapsedMicroseconds);
          if (engine.active != null || engine.retiringCount != 0) {
            throw StateError('lifecycle leaked');
          }
        }),
      );
      if (budget.used != 0 || budget.waiting != 0 || _Connection.live != 0) {
        throw StateError(
          'leak: permits=${budget.used} waiters=${budget.waiting} live=${_Connection.live}',
        );
      }
      peakRss = max(peakRss, ProcessInfo.currentRss);
    }
  } finally {
    await Future.wait(engines.map((engine) => engine.dispose()));
  }
  elapsed.stop();
  int percentile(List<int> values, double p) {
    if (values.isEmpty) return 0;
    values.sort();
    return values[((values.length - 1) * p).round()];
  }

  stdout.writeln(
    'engine_stress cycles=$cycles devices=$devices elapsedMs=${elapsed.elapsedMilliseconds} '
    'readyP50Us=${percentile(latencies, .5)} readyP95Us=${percentile(latencies, .95)} readyMaxUs=${latencies.last} '
    'recoveries=${recoveries.length} recoveryP95Us=${percentile(recoveries, .95)} '
    'upgrades=${upgrades.length} upgradeP95Us=${percentile(upgrades, .95)} cleanupP95Us=${percentile(cleanup, .95)} '
    'peakRssBytes=$peakRss liveConnections=${_Connection.live} permits=${budget.used} waiting=${budget.waiting}',
  );
}

class _Connection implements PreparedConnection {
  _Connection(this.id, this.channel) {
    live++;
  }
  static int live = 0;
  @override
  final String id;
  @override
  final ChannelKind channel;
  final meter = TrafficMeter();
  final _health = StreamController<ConnectionHealth>.broadcast();
  bool closed = false;
  @override
  TrafficSnapshot get traffic => meter.snapshot;
  @override
  Stream<ConnectionHealth> get healthChanges => _health.stream;
  @override
  Future<bool> probe(Cancellation cancellation) async =>
      !closed && !cancellation.isCancelled;
  @override
  Future<void> close() async {
    if (closed) throw StateError('double close');
    closed = true;
    live--;
    await _health.close();
  }
}

class _Handover implements ConnectionHandover {
  @override
  Future<bool> activate(
    PreparedConnection? previous,
    PreparedConnection next,
    Cancellation cancellation,
  ) async {
    cancellation.check();
    return true;
  }
}
