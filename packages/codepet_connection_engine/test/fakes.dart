import 'dart:async';

import 'package:codepet_connection_engine/codepet_connection_engine.dart';

final class FakeConnection implements PreparedConnection {
  FakeConnection(this.id, this.channel);
  @override
  final String id;
  @override
  final ChannelKind channel;
  final health = StreamController<ConnectionHealth>(onCancel: () async {});
  final meter = TrafficMeter();
  bool alive = true;
  int closes = 0, probes = 0;
  Completer<void>? closeBarrier;
  Object? closeError;
  Future<bool> Function()? onProbe;
  @override
  Stream<ConnectionHealth> get healthChanges => health.stream;
  @override
  TrafficSnapshot get traffic => meter.snapshot;
  @override
  Future<bool> probe(Cancellation cancellation) async {
    probes++;
    return onProbe == null ? alive : onProbe!();
  }

  @override
  Future<void> close() async {
    closes++;
    if (closeError != null) throw closeError!;
    await closeBarrier?.future;
    alive = false;
    // A never-subscribed stream does not complete done. Native transport
    // closure is independent of whether an observer was attached.
    unawaited(health.close());
  }
}

final class FakeHandover implements ConnectionHandover {
  final activated = <String>[];
  Future<bool> Function(PreparedConnection?, PreparedConnection, Cancellation)?
  run;
  @override
  Future<bool> activate(
    PreparedConnection? previous,
    PreparedConnection next,
    Cancellation cancel,
  ) async {
    cancel.check();
    final result = run == null ? true : await run!(previous, next, cancel);
    cancel.check();
    if (result) activated.add(next.id);
    return result;
  }
}

ConnectionTarget target(
  List<CandidateRoute> routes, {
  int environment = 0,
  int authorization = 0,
}) => ConnectionTarget(
  id: 'host',
  authorizationRevision: authorization,
  environmentRevision: environment,
  routes: routes,
);
CandidateRoute immediate(FakeConnection connection) =>
    CandidateRoute(kind: connection.channel, open: (_) async => connection);
