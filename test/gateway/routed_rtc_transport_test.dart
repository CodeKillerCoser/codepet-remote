import 'package:codepet_remote/core/domain/connection_traffic.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:codepet_remote/diagnostics/app_log.dart';
import 'package:codepet_remote/diagnostics/local_log_store.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:codepet_remote/gateway/webrtc/routed_rtc_transport.dart';

class Candidate
    implements
        GatewayTransport,
        EndpointAwareGatewayTransport,
        EndpointPersistenceAwareGatewayTransport, MetricsGatewayTransport {
  @override
  ConnectionTraffic connectionTraffic = const ConnectionTraffic(channel: 'unknown');
  final ready = Completer<void>();
  final output = StreamController<JsonMap>.broadcast();
  bool started = false, closed = false;
  int requests = 0;
  Object? synchronousFailure;
  @override
  Stream<JsonMap> get events => output.stream;
  @override
  Future<void> connect() {
    started = true;
    if (synchronousFailure != null) throw synchronousFailure!;
    return ready.future;
  }

  @override
  Future<Object?> request(Map<String, Object?> request) async {
    requests++;
    return 'ok';
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await output.close();
  }

  @override
  Uri get selectedGatewayUri => Uri.parse('wss://192.0.2.1:47622');
  @override
  bool get shouldPersistSelectedGatewayUri => true;
}

Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  test('metrics expose only the winning business channel', () async {
    final lan = Candidate()..connectionTraffic = const ConnectionTraffic(channel:'lan', sentBytes:999);
    final relay = Candidate()..connectionTraffic = const ConnectionTraffic(channel:'relay', receivedBytes:123);
    final route = RoutedRtcTransport.withRoutes(local:lan, cloudRoutes:() async => [RtcRouteAttempt('relay', relay)]);
    addTearDown(route.close);
    expect(route.connectionTraffic, isNull);
    final connected = route.connect();
    await tick(); relay.ready.complete(); await connected;
    expect(route.connectionTraffic!.channel, 'relay');
    expect(route.connectionTraffic!.totalBytes, 123);
  });

  test(
    'exported logs correlate race outcomes and distinguish cancellation',
    () async {
      final directory = await Directory.systemTemp.createTemp('rtc-race-logs');
      await AppLog.initialize(
        store: await LocalLogStore.open(rootDirectory: directory),
      );
      final lan = Candidate(), relay = Candidate();
      final route = RoutedRtcTransport.withRoutes(
        local: lan,
        cloudRoutes: () async => [RtcRouteAttempt('relay', relay)],
      );
      try {
        final connected = route.connect();
        await tick();
        relay.ready.complete();
        await connected;
        await tick();
        await route.close();
        final zipPath = await AppLog.exportLogs();
        final archive = ZipDecoder().decodeBytes(
          await File(zipPath).readAsBytes(),
        );
        final log = utf8.decode(
          archive.files.firstWhere((f) => f.name == 'codepet.log').content
              as List<int>,
        );
        final entries = const LineSplitter()
            .convert(log)
            .where((line) => line.contains('[gateway.rtc.diagnostic]'))
            .toList();
        final raceIds = entries
            .map(
              (line) => RegExp(r'raceId=([^ |]+)').firstMatch(line)?.group(1),
            )
            .toSet();
        expect(raceIds, hasLength(1));
        expect(raceIds.single, isNotNull);
        expect(
          entries.every(
            (line) =>
                RegExp(r'^\d{4}-\d{2}-\d{2} .*pid=\d+ thread=\d+ ')
                    .hasMatch(line),
          ),
          isTrue,
        );
        expect(
          entries.where((line) => line.contains('] race.path.start ')),
          hasLength(2),
        );
        expect(
          entries.singleWhere((line) => line.contains('] race.selected ')),
          contains('path=relay'),
        );
        final loser = entries.singleWhere(
          (line) => line.contains('] race.path.result '),
        );
        expect(loser, contains('path=lan'));
        expect(loser, contains('outcome=cancelled'));
        expect(loser, contains('reason=anotherPathSelected'));
        expect(
          entries.where((line) => line.contains('] race.failed ')),
          isEmpty,
        );
        expect(
          archive.files.any((file) => file.name.endsWith('.jsonl')),
          isFalse,
        );
      } finally {
        await route.close();
        await AppLog.resetForTesting();
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'synchronous connect failure does not leak cancellation errors',
    () async {
      final lan = Candidate()
        ..synchronousFailure = const GatewayConnectionException(
          'native unavailable',
          retryable: true,
        );
      final relay = Candidate();
      final route = RoutedRtcTransport.withRoutes(
        local: lan,
        cloudRoutes: () async => [RtcRouteAttempt('relay', relay)],
      );
      final connected = route.connect();
      await tick();
      relay.ready.complete();
      await connected;
      expect(route.selectedRoute, 'relay');
      expect(lan.closed, isTrue);
      await route.close();
    },
  );
  for (var winner = 0; winner < 4; winner++) {
    test(
      'all four paths start together; path $winner wins without waiting for others',
      () async {
        final candidates = List.generate(4, (_) => Candidate());
        var bootstraps = 0;
        final route = RoutedRtcTransport.withRoutes(
          local: candidates[0],
          bootstrap: (_) async {
            bootstraps++;
          },
          cloudRoutes: () async => [
            for (var n = 1; n < 4; n++)
              RtcRouteAttempt('path-$n', candidates[n]),
          ],
        );
        final errors = <Object>[];
        final events = <JsonMap>[];
        final subscription = route.events.listen(
          events.add,
          onError: errors.add,
        );
        final connected = route.connect();
        await tick();
        expect(candidates.every((c) => c.started), isTrue);
        // Losing stream failures must not leak into the live Gateway session.
        candidates[(winner + 1) % 4].output.addError(
          const GatewayConnectionException('unreachable', retryable: true),
        );
        candidates[winner].ready.complete();
        await connected.timeout(const Duration(seconds: 1));
        await tick();
        expect(route.selectedRoute, winner == 0 ? 'lan' : 'path-$winner');
        expect(route.selectedGatewayUri != null, winner == 0);
        expect(route.shouldPersistSelectedGatewayUri, winner == 0);
        expect(bootstraps, winner == 0 ? 1 : 0);
        expect(candidates[winner].closed, isFalse);
        expect([
          for (var n = 0; n < 4; n++)
            if (n != winner) candidates[n].closed,
        ], everyElement(isTrue));
        await route.request({'id': 'one', 'method': 'write'});
        expect(candidates.map((c) => c.requests).toList(), [
          for (var n = 0; n < 4; n++) n == winner ? 1 : 0,
        ]);
        candidates[winner].output.add({'method': 'event'});
        await tick();
        expect(events, hasLength(1));
        expect(errors, isEmpty);
        // A late successful loser cannot replace the winner.
        for (var n = 0; n < 4; n++) {
          if (!candidates[n].ready.isCompleted) candidates[n].ready.complete();
        }
        await tick();
        expect(route.selectedRoute, winner == 0 ? 'lan' : 'path-$winner');
        await route.close();
        await subscription.cancel();
      },
    );
  }

  test(
    'close during race rejects connect and disposes every attempt',
    () async {
      final candidates = List.generate(4, (_) => Candidate());
      final route = RoutedRtcTransport.withRoutes(
        local: candidates[0],
        cloudRoutes: () async => [
          for (var n = 1; n < 4; n++) RtcRouteAttempt('$n', candidates[n]),
        ],
      );
      final result = expectLater(
        route.connect(),
        throwsA(isA<GatewayConnectionException>()),
      );
      await tick();
      await route.close();
      await result;
      expect(candidates.every((c) => c.closed), isTrue);
      for (final candidate in candidates) {
        candidate.ready.complete();
      }
      await tick();
      expect(route.selectedRoute, isNull);
    },
  );

  test('one failure or timeout does not stop another pending path', () async {
    final lan = Candidate(), v6 = Candidate(), relay = Candidate();
    final route = RoutedRtcTransport.withRoutes(
      local: lan,
      cloudRoutes: () async => [
        RtcRouteAttempt('ipv6', v6, timeout: const Duration(milliseconds: 5)),
        RtcRouteAttempt('relay', relay),
      ],
    );
    final connected = route.connect();
    await tick();
    lan.ready.completeError(const GatewayConnectionException('pin rejected'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(v6.closed, isTrue);
    expect(relay.closed, isFalse);
    relay.ready.complete();
    await connected;
    expect(route.selectedRoute, 'relay');
    await route.close();
    v6.ready.complete();
  });

  test('all failures preserve nonretryable authentication error', () async {
    final lan = Candidate(), cloud = Candidate();
    final route = RoutedRtcTransport.withRoutes(
      local: lan,
      cloudRoutes: () async => [RtcRouteAttempt('cloud', cloud)],
    );
    final result = expectLater(
      route.connect(),
      throwsA(
        isA<GatewayConnectionException>().having(
          (e) => e.retryable,
          'retryable',
          false,
        ),
      ),
    );
    await tick();
    lan.ready.completeError(
      const GatewayConnectionException('unreachable', retryable: true),
    );
    cloud.ready.completeError(
      const GatewayConnectionException('signature rejected'),
    );
    await result;
    await route.close();
  });

  test('LAN winner does not wait for cloud storage or bootstrap', () async {
    final lan = Candidate(), late = Candidate();
    final storage = Completer<List<RtcRouteAttempt>>();
    final bootstrap = Completer<void>();
    final route = RoutedRtcTransport.withRoutes(
      local: lan,
      cloudRoutes: () => storage.future,
      bootstrap: (_) => bootstrap.future,
    );
    final connected = route.connect();
    lan.ready.complete();
    await connected.timeout(const Duration(seconds: 1));
    storage.complete([RtcRouteAttempt('late', late)]);
    await tick();
    expect(late.started, isFalse);
    expect(late.closed, isTrue);
    bootstrap.complete();
    await route.close();
  });
}
