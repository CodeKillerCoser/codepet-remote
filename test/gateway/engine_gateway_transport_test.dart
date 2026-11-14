import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_connection_engine/codepet_connection_engine.dart' as ce;
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/connection_traffic.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:codepet_remote/gateway/connection/engine_gateway_transport.dart';
import 'package:codepet_remote/gateway/webrtc/webrtc_gateway_transport.dart';

import 'webrtc_transport_test.dart' show FakePeer, FakeSignaling, eventually;

final handshake = <String, Object?>{
  'jsonrpc': '2.0',
  'id': 'handshake',
  'method': 'protocol.handshake',
  'params': <String, Object?>{},
};
Map<String, Object?> rpc(String method) => {
  'jsonrpc': '2.0',
  'id': method,
  'method': method,
  'params': <String, Object?>{},
};
Future<void> flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'native cleanup failure retains budget across repeated reconnect inputs',
    () async {
      final budget = ce.CandidateBudget(limit: 1);
      final peer = FakePeer()
        ..disposeAction = () async => throw StateError('native dispose failed');
      var opened = 0;
      final transport = EngineGatewayTransport(
        targetId: 'host',
        kinds: [ce.ChannelKind.relay],
        budget: budget,
        policy: const ce.ConnectionPolicy(
          retry: Duration(milliseconds: 5),
          cleanupTimeout: Duration(milliseconds: 10),
        ),
        openTransport: (_, _) async {
          opened++;
          return WebRtcGatewayTransport(
            signaling: FakeSignaling(failure: StateError('answer failed')),
            peerFactory: () async => peer,
          );
        },
      );
      final request = expectLater(
        transport.request(handshake),
        throwsException,
      );
      await eventually(() => peer.disposeCalls == 1);
      for (var i = 0; i < 100; i++) {
        transport.reconcile();
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(opened, 1);
      expect(budget.used, 1);
      await transport.close();
      await request;
      expect(opened, 1);
    },
  );

  test('slow WSS pong preserves bounded heartbeat grace instead of aborting bulk transfer', () async {
    final owner = Owner();
    late FakeRoute route;
    final transport = EngineGatewayTransport(
      targetId: 'host',
      kinds: [ce.ChannelKind.lan],
      openTransport: (kind, _) async => route = FakeRoute(owner, kind, 'lan'),
    );
    await transport.request(handshake);
    final pong = Completer<void>();
    route.pingReply = pong.future;
    transport.reconcile();
    await Future<void>.delayed(const Duration(milliseconds: 4300));
    expect(route.closed, false);
    expect(owner.switches, 1);
    expect(transport.connectionTraffic?.channel, 'lan');
    pong.complete();
    await flush();
    await transport.close();
  });

  test('prepared paths do not subscribe, relay then LAN commits and resumes cursor once', () async {
    final host = Owner();
    final lanReady = Completer<void>();
    final all = <FakeRoute>[];
    final transport = EngineGatewayTransport(
      targetId: 'host',
      kinds: [ce.ChannelKind.lan, ce.ChannelKind.relay],
      policy: const ce.ConnectionPolicy(
        stability: Duration.zero,
        upgradeCooldown: Duration.zero,
      ),
      openTransport: (kind, _) async {
        final route = FakeRoute(
          host,
          kind,
          '${all.length}',
          ready: kind == ce.ChannelKind.lan ? lanReady.future : null,
        );
        all.add(route);
        return route;
      },
    );
    final events = <JsonMap>[];
    final subscription = transport.events.listen(events.add);
    await transport.connect();
    await transport.request(handshake);
    expect(transport.connectionTraffic?.channel, 'relay');
    await transport.request({
      ...rpc('event.subscribe'),
      'params': {'afterCursor': 'cursor1'},
    });
    final relay = all.singleWhere((r) => r.kind == ce.ChannelKind.relay);
    relay.output.add({
      'jsonrpc': '2.0',
      'method': 'event.test',
      'params': {'eventCursor': 'cursor2', 'payload': {}},
    });
    await flush();
    lanReady.complete();
    await flush();
    expect(transport.connectionTraffic?.channel, 'lan');
    final lan = all.singleWhere((r) => r.kind == ce.ChannelKind.lan);
    expect(lan.subscribeCursors, ['cursor2']);
    expect(relay.closed, isTrue);
    expect(events.length, 1);
    await transport.request(rpc('write'));
    expect(lan.writes, 1);
    expect(relay.writes, 0);
    await transport.close();
    await subscription.cancel();
    expect(all.every((r) => r.closed), isTrue);
  });
  test(
    'lost activation ACK is resolved through authoritative status',
    () async {
      final owner = Owner()..loseAck = true;
      final transport = EngineGatewayTransport(
        targetId: 'host',
        kinds: [ce.ChannelKind.lan],
        openTransport: (kind, _) async => FakeRoute(owner, kind, 'lan'),
      );
      await transport.request(handshake);
      expect(owner.active, 'lan');
      expect(owner.switches, 1);
      expect(transport.connectionTraffic?.channel, 'lan');
      await transport.close();
    },
  );
  test(
    'healthy upgrade waits for outstanding write, does not resend it',
    () async {
      final owner = Owner();
      final lanReady = Completer<void>();
      final reply = Completer<void>();
      late FakeRoute relay;
      final transport = EngineGatewayTransport(
        targetId: 'host',
        kinds: [ce.ChannelKind.lan, ce.ChannelKind.relay],
        policy: const ce.ConnectionPolicy(stability: Duration.zero),
        openTransport: (kind, _) async {
          final route = FakeRoute(
            owner,
            kind,
            kind.name,
            ready: kind == ce.ChannelKind.lan ? lanReady.future : null,
          );
          if (kind == ce.ChannelKind.relay) {
            relay = route;
            route.writeReply = reply.future;
          }
          return route;
        },
      );
      await transport.request(handshake);
      final writing = transport.request(rpc('write'));
      await flush();
      lanReady.complete();
      await flush();
      expect(owner.active, 'relay');
      expect(relay.writes, 1);
      reply.complete();
      await writing;
      await flush();
      expect(owner.active, 'lan');
      expect(relay.writes, 1);
      await transport.close();
    },
  );
  test(
    'hard close recovers through same owner; explicit close does not resurrect',
    () async {
      final owner = Owner();
      final routes = <FakeRoute>[];
      final transport = EngineGatewayTransport(
        targetId: 'host',
        kinds: [ce.ChannelKind.lan],
        openTransport: (kind, _) async {
          final r = FakeRoute(owner, kind, '${routes.length}');
          routes.add(r);
          return r;
        },
      );
      final states = <bool>[];
      final sub = transport.availability.listen(states.add);
      await transport.request(handshake);
      await routes.first.output.close();
      await flush();
      expect(routes.length, 2);
      expect(transport.connectionTraffic?.channel, 'lan');
      expect(states, [true, false, true]);
      await transport.close();
      transport.reconcile();
      await flush();
      expect(routes.length, 2);
      await sub.cancel();
    },
  );
  test(
    'legacy host receives no control frames and healthy path is kept',
    () async {
      final owner = Owner();
      final lanReady = Completer<void>();
      final routes = <FakeRoute>[];
      final transport = EngineGatewayTransport(
        targetId: 'host',
        kinds: [ce.ChannelKind.lan, ce.ChannelKind.relay],
        policy: const ce.ConnectionPolicy(stability: Duration.zero),
        openTransport: (kind, _) async {
          final r = FakeRoute(
            owner,
            kind,
            kind.name,
            ready: kind == ce.ChannelKind.lan ? lanReady.future : null,
          )..supportsChannelControl = false;
          routes.add(r);
          return r;
        },
      );
      await transport.request(handshake);
      lanReady.complete();
      await flush();
      expect(transport.connectionTraffic?.channel, 'relay');
      expect(owner.switches, 0);
      expect(routes.every((r) => r.controls == 0), isTrue);
      await transport.close();
    },
  );
  test(
    'ordinary request timeout is not a reconnect or replay signal',
    () async {
      final owner = Owner();
      late FakeRoute route;
      final transport = EngineGatewayTransport(
        targetId: 'host',
        kinds: [ce.ChannelKind.lan],
        openTransport: (kind, _) async => route = FakeRoute(owner, kind, 'lan'),
      );
      await transport.request(handshake);
      route.writeReply = Future<void>.error(TimeoutException('slow business'));
      await expectLater(
        transport.request(rpc('write')),
        throwsA(isA<TimeoutException>()),
      );
      expect(route.closed, isFalse);
      expect(route.writes, 1);
      expect(owner.switches, 1);
      await transport.close();
    },
  );
}

class Owner {
  String? active, lastSwitch;
  bool loseAck = false;
  int switches = 0;
}

class FakeRoute
    implements
        GatewayTransport,
        ChannelControlGatewayTransport,
        MetricsGatewayTransport {
  FakeRoute(this.owner, this.kind, this.id, {this.ready});
  final Owner owner;
  final ce.ChannelKind kind;
  final String id;
  final Future<void>? ready;
  final output = StreamController<JsonMap>.broadcast();
  bool closed = false;
  int writes = 0, controls = 0;
  Future<void>? writeReply, pingReply;
  final subscribeCursors = <String>[];
  @override
  bool supportsChannelControl = true;
  @override
  ConnectionTraffic get connectionTraffic =>
      ConnectionTraffic(channel: kind.name);
  @override
  Stream<JsonMap> get events => output.stream;
  @override
  Future<void> connect() async {
    await ready;
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await output.close();
  }

  @override
  Future<Object?> request(Map<String, Object?> request) async {
    if (request['channelControl'] == 1) {
      controls++;
      if (!supportsChannelControl) throw StateError('unnegotiated control');
      if (request['operation'] == 'activate') {
        final params = request['params'] as Map;
        if (params['expectedActive'] != owner.active) {
          throw StateError('CAS conflict');
        }
        owner.active = id;
        owner.lastSwitch = params['switchId'] as String;
        owner.switches++;
        if (owner.loseAck) {
          owner.loseAck = false;
          throw TimeoutException('lost ack');
        }
      }
      return {
        'channelControl': 1,
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {
          'connectionId': id,
          if (owner.active != null) 'activeConnectionId': owner.active,
          if (owner.lastSwitch != null) 'lastSwitchId': owner.lastSwitch,
        },
      };
    }
    final params = request['params'] as Map;
    Object result;
    switch (request['method']) {
      case 'protocol.handshake':
        result = {
          'protocol': {'version': 2, 'minVersion': 2, 'selectedVersion': 2},
          'device': {
            'name': 'Host',
            'operatingSystem': 'Test',
            'systemVersion': '1',
          },
          'providers': [],
          'eventCursor': 'cursor1',
        };
      case 'protocol.ping':
        await pingReply;
        result = {'sequence': params['sequence'], 'providers': []};
      case 'event.subscribe':
        subscribeCursors.add(params['afterCursor'] as String);
        result = {'subscribedAfterCursor': params['afterCursor']};
      default:
        writes++;
        await writeReply;
        result = {};
    }
    return {'jsonrpc': '2.0', 'id': request['id'], 'result': result};
  }
}
