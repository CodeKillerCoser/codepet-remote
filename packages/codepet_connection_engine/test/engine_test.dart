import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:fake_async/fake_async.dart';
import 'package:codepet_connection_engine/codepet_connection_engine.dart';

import 'fakes.dart';

void main() {
  test('core has no Flutter, application, protocol, IO or network imports', () {
    for (final file in Directory(
      'lib',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      for (final line in file.readAsLinesSync().where(
        (l) => l.startsWith('import ') || l.startsWith('export '),
      )) {
        expect(
          line,
          isNot(
            matches(r'dart:(io|ui)|package:|application/|gateway/|features/'),
          ),
        );
      }
    }
  });
  test('parallel startup, duplicate requests merge, ready preference is deterministic', () {
    fakeAsync((async) {
      final handover = FakeHandover();
      final engine = ConnectionEngine(handover: handover);
      final connections = ChannelKind.values
          .map((k) => FakeConnection(k.name, k))
          .toList();
      final routes = connections.reversed.map(immediate).toList();
      for (var i = 0; i < 100; i++) {
        engine.reconcile(target(routes));
      }
      async.flushMicrotasks();
      expect(handover.activated, ['lan']);
      expect(engine.snapshot.channel, ChannelKind.lan);
      expect(engine.snapshot.candidateCount, 0);
      for (final c in connections.skip(1)) {
        expect(c.closes, 1);
      }
      engine.dispose();
      async.flushMicrotasks();
      expect(engine.budget.used, 0);
      expect(async.periodicTimerCount, 0);
      expect(async.nonPeriodicTimerCount, 0);
    });
  });
  test('relay first remains usable then upgrades to IPv6 and finally LAN', () {
    fakeAsync((async) {
      final bridge = FakeHandover();
      final engine = ConnectionEngine(
        handover: bridge,
        nowMilliseconds: () => async.elapsed.inMilliseconds,
        policy: const ConnectionPolicy(upgradeCooldown: Duration(seconds: 3)),
      );
      final lan = FakeConnection('lan', ChannelKind.lan);
      final ipv6 = FakeConnection('v6', ChannelKind.ipv6Direct);
      final relay = FakeConnection('relay', ChannelKind.relay)
        ..meter.record(received: 123);
      final lanReady = Completer<PreparedConnection>(),
          ipv6Ready = Completer<PreparedConnection>();
      engine.reconcile(
        target([
          CandidateRoute(kind: ChannelKind.lan, open: (_) => lanReady.future),
          CandidateRoute(
            kind: ChannelKind.ipv6Direct,
            open: (_) => ipv6Ready.future,
          ),
          immediate(relay),
        ]),
      );
      async.flushMicrotasks();
      expect(engine.active, relay);
      expect(engine.snapshot.traffic!.totalBytes, 123);
      ipv6Ready.complete(ipv6);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(engine.active, relay);
      async.elapse(const Duration(seconds: 1));
      expect(engine.active, ipv6);
      expect(engine.snapshot.traffic!.totalBytes, 0);
      lanReady.complete(lan);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));
      expect(engine.active, lan);
      expect(bridge.activated, ['relay', 'v6', 'lan']);
      expect(relay.closes, 1);
      expect(ipv6.closes, 1);
      engine.dispose();
      async.flushMicrotasks();
      expect(engine.budget.used, 0);
    });
  });
  test(
    'active stream done immediately recovers and late events cannot replace it',
    () {
      fakeAsync((async) {
        final engine = ConnectionEngine(handover: FakeHandover());
        final connections = <FakeConnection>[];
        engine.reconcile(
          target([
            CandidateRoute(
              kind: ChannelKind.lan,
              open: (_) async {
                final c = FakeConnection(
                  '${connections.length}',
                  ChannelKind.lan,
                );
                connections.add(c);
                return c;
              },
            ),
          ]),
        );
        async.flushMicrotasks();
        connections.first.health.close();
        async.flushMicrotasks();
        expect(connections.length, 2);
        expect(engine.active, connections.last);
        engine.dispose();
        async.flushMicrotasks();
      });
    },
  );
  test(
    'timed out native open retains its permit and late success is closed',
    () {
      fakeAsync((async) {
        final budget = CandidateBudget(limit: 1);
        final engine = ConnectionEngine(
          handover: FakeHandover(),
          budget: budget,
        );
        final late = Completer<PreparedConnection>();
        engine.reconcile(
          target([
            CandidateRoute(
              kind: ChannelKind.lan,
              timeout: const Duration(seconds: 1),
              open: (_) => late.future,
            ),
          ]),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(budget.used, 1);
        engine.disconnect();
        async.flushMicrotasks();
        final c = FakeConnection('late', ChannelKind.lan);
        late.complete(c);
        async.flushMicrotasks();
        expect(c.closes, 1);
        expect(engine.active, isNull);
        expect(budget.used, 0);
        expect(engine.retiringCount, 0);
        engine.dispose();
        async.flushMicrotasks();
      });
    },
  );
  test('cancellation while queued or granted returns every permit', () {
    fakeAsync((async) {
      final budget = CandidateBudget(limit: 1);
      final engine = ConnectionEngine(handover: FakeHandover(), budget: budget);
      engine.reconcile(
        target(
          ChannelKind.values
              .map((kind) => immediate(FakeConnection(kind.name, kind)))
              .toList(),
        ),
      );
      engine.disconnect();
      async.flushMicrotasks();
      expect(budget.used, 0);
      expect(budget.waiting, 0);
      expect(engine.retiringCount, 0);
      engine.dispose();
      async.flushMicrotasks();
    });
  });
  test('permanent failure blocks same authorization, fresh authorization can recover', () {
    fakeAsync((async) {
      final engine = ConnectionEngine(handover: FakeHandover());
      var opens = 0;
      final bad = CandidateRoute(
        kind: ChannelKind.lan,
        open: (_) async {
          opens++;
          throw const ConnectionFailure('revoked', permanent: true);
        },
      );
      engine.reconcile(target([bad]));
      async.flushMicrotasks();
      expect(engine.snapshot.phase, ConnectionPhase.blocked);
      engine.reconcile(target([bad], environment: 1));
      async.flushMicrotasks();
      expect(opens, 1);
      engine.reconcile(
        target([
          immediate(FakeConnection('new', ChannelKind.lan)),
        ], authorization: 1),
      );
      async.flushMicrotasks();
      expect(engine.active!.id, 'new');
      engine.dispose();
      async.flushMicrotasks();
    });
  });
  test(
    'failed optimization leaves old connection, unknown commit fences both',
    () {
      fakeAsync((async) {
        final bridge = FakeHandover();
        final engine = ConnectionEngine(
          handover: bridge,
          nowMilliseconds: () => async.elapsed.inMilliseconds,
          policy: const ConnectionPolicy(stability: Duration.zero),
        );
        final relay = FakeConnection('relay', ChannelKind.relay);
        engine.reconcile(target([immediate(relay)]));
        async.flushMicrotasks();
        bridge.run = (_, _, _) async => false;
        engine.reconcile(
          target([
            immediate(FakeConnection('lan', ChannelKind.lan)),
          ], environment: 1),
        );
        async.flushMicrotasks();
        expect(engine.active, relay);
        bridge.run = (_, _, _) async =>
            throw const ConnectionFailure('unknown_commit', permanent: true);
        engine.reconcile(
          target([
            immediate(FakeConnection('lan2', ChannelKind.lan)),
          ], environment: 2),
        );
        async.flushMicrotasks();
        expect(engine.active, isNull);
        expect(engine.snapshot.phase, ConnectionPhase.blocked);
        engine.dispose();
        async.flushMicrotasks();
      });
    },
  );
  test(
    'zero throughput is healthy; failed probes need threshold, then recover',
    () {
      fakeAsync((async) {
        final all = <FakeConnection>[];
        final engine = ConnectionEngine(
          handover: FakeHandover(),
          policy: const ConnectionPolicy(probeInterval: Duration(seconds: 1)),
        );
        engine.reconcile(
          target([
            CandidateRoute(
              kind: ChannelKind.lan,
              open: (_) async {
                final c = FakeConnection('${all.length}', ChannelKind.lan);
                all.add(c);
                return c;
              },
            ),
          ]),
        );
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 2));
        expect(all.length, 1);
        all.first.alive = false;
        async.elapse(const Duration(seconds: 1));
        expect(engine.snapshot.health, ConnectionHealth.suspect);
        async.elapse(const Duration(seconds: 1));
        expect(all.length, 2);
        engine.dispose();
        async.flushMicrotasks();
      });
    },
  );
  test(
    '1000 establish/disconnect cycles release all tasks, permits and timers',
    () {
      fakeAsync((async) {
        final engine = ConnectionEngine(handover: FakeHandover());
        for (var i = 0; i < 1000; i++) {
          engine.reconcile(
            target(
              ChannelKind.values
                  .map((k) => immediate(FakeConnection('$i-${k.name}', k)))
                  .toList(),
            ),
          );
          async.flushMicrotasks();
          expect(engine.active!.channel, ChannelKind.lan);
          engine.disconnect();
          async.flushMicrotasks();
          expect(engine.budget.used, 0);
          expect(engine.budget.waiting, 0);
          expect(engine.retiringCount, 0);
          expect(async.periodicTimerCount, 0);
          expect(async.nonPeriodicTimerCount, 0);
        }
        engine.dispose();
        async.flushMicrotasks();
      });
    },
  );
}
