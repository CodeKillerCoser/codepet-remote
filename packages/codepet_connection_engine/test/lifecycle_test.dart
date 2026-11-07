import 'dart:async';

import 'package:codepet_connection_engine/codepet_connection_engine.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  test('open failure with unconfirmed native cleanup retains its permit', () {
    fakeAsync((clock) {
      final engine = ConnectionEngine(handover: FakeHandover());
      engine.reconcile(
        target([
          CandidateRoute(
            kind: ChannelKind.lan,
            open: (_) async {
              throw const ConnectionFailure(
                'prepare_close_failed',
                unreleasedResources: true,
              );
            },
          ),
        ]),
      );
      clock.flushMicrotasks();
      expect(engine.budget.used, 1);
      expect(engine.retiringCount, 1);
      engine.dispose();
      clock.elapse(const Duration(seconds: 3));
      expect(engine.budget.used, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('failed native close quarantines its slot instead of admitting unbounded replacements', () {
    fakeAsync((clock) {
      final broken = FakeConnection('relay', ChannelKind.relay)
        ..closeError = StateError('native close failed');
      final engine = ConnectionEngine(handover: FakeHandover());
      engine.reconcile(
        target([
          immediate(FakeConnection('lan', ChannelKind.lan)),
          immediate(broken),
        ]),
      );
      clock.flushMicrotasks();
      expect(engine.budget.used, 1);
      expect(engine.retiringCount, 1);
      engine.dispose();
      clock.elapse(const Duration(seconds: 3));
      expect(engine.snapshot.phase, ConnectionPhase.disposed);
      expect(engine.budget.used, 1);
      expect(clock.pendingTimers, isEmpty);
    });
  });

  test('queued recovery takes precedence over healthy optimization without displacing an active peer', () async {
    final budget = CandidateBudget(limit: 1);
    final first = await budget.acquire(Cancellation());
    final order = <String>[];
    final optimizing = budget.acquire(Cancellation(), priority: 1).then((
      lease,
    ) {
      order.add('optimize');
      lease.release();
    });
    final recovery = budget.acquire(Cancellation(), priority: 0).then((lease) {
      order.add('recover');
      lease.release();
    });
    first.release();
    await Future.wait([optimizing, recovery]);
    expect(order, ['recover', 'optimize']);
    expect(budget.used, 0);
  });

  test(
    'optimization budget can pause while recovery and health remain active',
    () {
      fakeAsync((clock) {
        final relay = FakeConnection('relay', ChannelKind.relay);
        var lanOpens = 0;
        final lan = CandidateRoute(
          kind: ChannelKind.lan,
          open: (_) async {
            lanOpens++;
            return FakeConnection('lan', ChannelKind.lan);
          },
        );
        final engine = ConnectionEngine(
          handover: FakeHandover(),
          nowMilliseconds: () => clock.elapsed.inMilliseconds,
          policy: const ConnectionPolicy(stability: Duration.zero),
        );
        engine.reconcile(target([immediate(relay)]));
        clock.flushMicrotasks();
        engine.reconcile(
          ConnectionTarget(
            id: 'host',
            authorizationRevision: 0,
            environmentRevision: 1,
            optimize: false,
            routes: [lan],
          ),
        );
        clock.elapse(const Duration(minutes: 2));
        expect(engine.active, relay);
        expect(lanOpens, 0);
        expect(relay.probes, greaterThan(1));
        relay.health.add(ConnectionHealth.unusable);
        clock.flushMicrotasks();
        expect(lanOpens, 1);
        expect(engine.active!.channel, ChannelKind.lan);
        engine.dispose();
        clock.flushMicrotasks();
        expect(clock.pendingTimers, isEmpty);
      });
    },
  );

  test('dispose fences immediately even when native close never completes', () {
    fakeAsync((clock) {
      final connection = FakeConnection('lan', ChannelKind.lan)
        ..closeBarrier = Completer<void>();
      final engine = ConnectionEngine(handover: FakeHandover());
      engine.reconcile(target([immediate(connection)]));
      clock.flushMicrotasks();
      final disposal = engine.dispose();
      expect(identical(disposal, engine.dispose()), isTrue);
      expect(() => engine.reconcile(target([])), throwsStateError);
      clock.elapse(const Duration(seconds: 3));
      expect(engine.snapshot.phase, ConnectionPhase.disposed);
      connection.closeBarrier!.complete();
      clock.flushMicrotasks();
      expect(engine.retiringCount, 0);
      expect(clock.pendingTimers, isEmpty);
    });
  });
  test('cancel activation, start new epoch, ignore old commit and error', () {
    fakeAsync((clock) {
      final pending = Completer<bool>();
      final bridge = FakeHandover()..run = (_, _, _) => pending.future;
      final engine = ConnectionEngine(handover: bridge);
      final old = FakeConnection('old', ChannelKind.lan);
      engine.reconcile(target([immediate(old)]));
      clock.flushMicrotasks();
      engine.disconnect();
      clock.flushMicrotasks();
      bridge.run = null;
      engine.reconcile(
        target([immediate(FakeConnection('new', ChannelKind.lan))]),
      );
      clock.flushMicrotasks();
      expect(engine.active?.id, 'new');
      pending.completeError(StateError('late commit failed'));
      clock.flushMicrotasks();
      expect(engine.active?.id, 'new');
      expect(old.closes, 1);
      engine.dispose();
      clock.flushMicrotasks();
      expect(clock.pendingTimers, isEmpty);
    });
  });
  test('never-ready adapters cannot exceed global and retiring budgets', () {
    fakeAsync((clock) {
      final budget = CandidateBudget(limit: 8);
      final pending = <Completer<PreparedConnection>>[];
      final engines = List.generate(
        20,
        (_) => ConnectionEngine(handover: FakeHandover(), budget: budget),
      );
      final routes = ChannelKind.values
          .map(
            (kind) => CandidateRoute(
              kind: kind,
              timeout: const Duration(seconds: 1),
              open: (_) {
                final future = Completer<PreparedConnection>();
                pending.add(future);
                return future.future;
              },
            ),
          )
          .toList();
      for (final engine in engines) {
        engine.reconcile(target(routes));
      }
      clock.elapse(const Duration(minutes: 5));
      expect(pending.length, 8);
      expect(budget.used, 8);
      for (final engine in engines) {
        engine.dispose();
      }
      clock.elapse(const Duration(seconds: 3));
      expect(budget.waiting, 0);
      for (var i = 0; i < pending.length; i++) {
        pending[i].complete(
          FakeConnection('late$i', ChannelKind.values[i % 4]),
        );
      }
      clock.flushMicrotasks();
      expect(budget.used, 0);
      expect(clock.pendingTimers, isEmpty);
    });
  });
  test('empty routes wait for input without recurring timers', () {
    fakeAsync((clock) {
      final engine = ConnectionEngine(handover: FakeHandover());
      engine.reconcile(target([]));
      clock.elapse(const Duration(days: 1));
      expect(clock.pendingTimers, isEmpty);
      expect(engine.snapshot.phase, ConnectionPhase.waiting);
      engine.dispose();
      clock.flushMicrotasks();
    });
  });
  test('retry is bounded and fresh environment replenishes immediately', () {
    fakeAsync((clock) {
      var opens = 0;
      final engine = ConnectionEngine(handover: FakeHandover());
      final routes = [
        CandidateRoute(
          kind: ChannelKind.lan,
          open: (_) async {
            opens++;
            throw const ConnectionFailure('unreachable');
          },
        ),
      ];
      engine.reconcile(target(routes));
      clock.elapse(const Duration(seconds: 61));
      expect(opens, lessThan(10));
      final before = opens;
      engine.reconcile(target(routes, environment: 1));
      clock.flushMicrotasks();
      expect(opens, before + 1);
      engine.dispose();
      clock.flushMicrotasks();
    });
  });
  test('a relay cannot masquerade as an IPv6 direct candidate', () {
    fakeAsync((clock) {
      final c = FakeConnection('bad', ChannelKind.relay);
      final engine = ConnectionEngine(handover: FakeHandover());
      engine.reconcile(
        target([
          CandidateRoute(kind: ChannelKind.ipv6Direct, open: (_) async => c),
        ]),
      );
      clock.flushMicrotasks();
      expect(engine.active, isNull);
      expect(engine.snapshot.errorCode, 'candidate_channel_mismatch');
      expect(c.closes, 1);
      engine.dispose();
      clock.flushMicrotasks();
    });
  });
}
