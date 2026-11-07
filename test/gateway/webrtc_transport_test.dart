import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:codepet_remote/diagnostics/app_log.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/webrtc/framing.dart';
import 'package:codepet_remote/gateway/webrtc/signaling.dart';
import 'package:codepet_remote/gateway/webrtc/path_policy.dart';
import 'package:codepet_remote/gateway/webrtc/webrtc_gateway_transport.dart';

class FakeSignaling implements RtcSignaling {
  FakeSignaling({this.failure});
  final Object? failure;
  @override
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
    if (failure != null) throw failure!;
    expect(offer['type'], 'offer');
    return {'type': 'answer', 'sdp': 'test-answer'};
  }
}

class TrickleSignaling extends FakeSignaling implements RtcTrickleSignaling {
  TrickleSignaling(this.peer);
  final DelayedGatheringPeer peer;
  final candidates = <Map<String, dynamic>?>[];
  bool finished = false;
  @override
  bool trickleEnabled = true;
  @override
  Future<Map<String, dynamic>> configuration() async => {};
  @override
  void localCandidate(Map<String, dynamic>? candidate) {
    candidates.add(candidate);
  }

  @override
  void checkTrickleFailure() {}
  @override
  void finishTrickle() {
    finished = true;
  }

  @override
  void close() {
    finished = true;
  }

  @override
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
    expect(
      peer.gatheringFinished,
      false,
      reason: 'Offer must not wait for slow ICE gathering',
    );
    expect(offer['sdp'], isNot(contains('a=candidate:')));
    // A useful candidate arrives after the initial offer was already submitted.
    peer.onIceCandidate?.call(
      RTCIceCandidate('candidate:1 1 udp 1 192.0.2.1 1234 typ host', '0', 0),
    );
    peer.finishGathering();
    return {
      'type': 'answer',
      'sdp': 'v=0\r\na=candidate:2 1 udp 1 192.0.2.2 1234 typ host\r\n',
    };
  }
}

class DelayedGatheringPeer extends FakePeer {
  bool gatheringFinished = false;
  @override
  Future<RTCIceGatheringState?> getIceGatheringState() async =>
      gatheringFinished
      ? RTCIceGatheringState.RTCIceGatheringStateComplete
      : RTCIceGatheringState.RTCIceGatheringStateGathering;
  @override
  Future<RTCSessionDescription?> getLocalDescription() async =>
      RTCSessionDescription('v=0\r\n', 'offer');
  void finishGathering() {
    gatheringFinished = true;
    onIceGatheringState?.call(
      RTCIceGatheringState.RTCIceGatheringStateComplete,
    );
  }
}

class FakePeer extends RTCPeerConnection {
  final channel = FakeChannel();
  RTCDataChannelInit? init;
  bool disposed = false;
  int statsCalls = 0;
  List<StatsReport>? stats;
  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async {
    statsCalls++;
    return stats ??
        [
          StatsReport('pair', 'candidate-pair', 0, {
            'state': 'succeeded',
            'requestsSent': 3,
          }),
        ];
  }

  @override
  Future<RTCDataChannel> createDataChannel(
    String label,
    RTCDataChannelInit dataChannelDict,
  ) async {
    expect(label, 'codepet.gateway.v1');
    init = dataChannelDict;
    return channel;
  }

  @override
  Future<RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    expect(constraints?['mandatory'], {
      'OfferToReceiveAudio': false,
      'OfferToReceiveVideo': false,
    });
    return RTCSessionDescription('test-offer', 'offer');
  }

  @override
  Future<void> setLocalDescription(RTCSessionDescription description) async {}
  @override
  Future<RTCSessionDescription?> getLocalDescription() async =>
      RTCSessionDescription('test-offer', 'offer');
  @override
  Future<RTCIceGatheringState?> getIceGatheringState() async =>
      RTCIceGatheringState.RTCIceGatheringStateComplete;
  @override
  Future<void> setRemoteDescription(RTCSessionDescription description) async {
    channel.currentState = RTCDataChannelState.RTCDataChannelOpen;
  }

  @override
  Future<void> close() async {
    await channel.close();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeChannel extends RTCDataChannel {
  RTCDataChannelState currentState =
      RTCDataChannelState.RTCDataChannelConnecting;
  int buffer = 0;
  bool autoReply = true;
  bool blockAfterFirstFrame = false;
  final sent = <Uint8List>[];
  final decoder = RtcDecoder(maximum: rtcRequestBytes);
  @override
  RTCDataChannelState get state => currentState;
  @override
  int get id => 0;
  @override
  String get label => 'codepet.gateway.v1';
  @override
  int get bufferedAmount => buffer;
  @override
  Future<int> getBufferedAmount() async => buffer;
  @override
  Future<void> send(RTCDataChannelMessage message) async {
    expect(message.isBinary, isTrue);
    sent.add(message.binary);
    if (blockAfterFirstFrame && sent.length == 1) buffer = 100000;
    final decoded = decoder.push(message.binary);
    if (decoded is RtcJson && autoReply) {
      final request = jsonDecode(utf8.decode(decoded.bytes)) as Map;
      emit({
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': {'text': '界'.padRight(80000, 'x')},
      });
    }
  }

  void emit(Map<String, Object?> json) {
    final bytes = utf8.encode(jsonEncode(json));
    for (var offset = 0; offset < bytes.length;) {
      final end = (offset + rtcFrameBytes - rtcHeaderBytes).clamp(
        0,
        bytes.length,
      );
      onMessage?.call(
        RTCDataChannelMessage.fromBinary(
          rtcFragment(bytes.length, offset, bytes.sublist(offset, end)),
        ),
      );
      offset = end;
    }
  }

  @override
  Future<void> close() async {
    currentState = RTCDataChannelState.RTCDataChannelClosed;
  }
}

Future<void> eventually(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

void main() {
  test(
    'trickle starts before gathering completes and preserves late candidates',
    () async {
      final peer = DelayedGatheringPeer();
      final signaling = TrickleSignaling(peer);
      final transport = WebRtcGatewayTransport(
        signaling: signaling,
        peerFactory: () async => peer,
        pathPolicy: RtcPathPolicy.ipv4Direct,
      );
      addTearDown(transport.close);
      await transport.connect();
      expect(signaling.candidates.first?['candidate'], contains('192.0.2.1'));
      expect(signaling.candidates.last, null);
      expect(signaling.finished, true);
    },
  );
  test('small RPC keeps request correlation without duplicate frame lifecycle logs', () async {
    final events = <String>[];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen((record) {
      if (record.object case final StructuredLogEvent event) {
        events.add(event.event);
      }
    });
    final peer = FakePeer();
    final transport = WebRtcGatewayTransport(
      signaling: FakeSignaling(),
      peerFactory: () async => peer,
    );
    try {
      await transport.connect();
      peer.channel.autoReply = false;
      final response = transport.request({
        'id': 'small',
        'method': 'protocol.ping',
      });
      await eventually(() => peer.channel.sent.isNotEmpty);
      peer.channel.emit({'jsonrpc': '2.0', 'id': 'small', 'result': {}});
      await response;
      expect(events, containsAll(['rpc.queued', 'rpc.response']));
      expect(events, isNot(contains('message.send.start')));
      expect(events, isNot(contains('message.send.complete')));
      expect(events, isNot(contains('message.receive.complete')));
      peer.channel.emit({
        'jsonrpc': '2.0',
        'method': 'event',
        'params': 'x' * 80000,
      });
      expect(events, contains('message.receive.complete'));
    } finally {
      await transport.close();
      await subscription.cancel();
      Logger.root.level = previous;
    }
  });
  test('channel follows selected ICE pair, including relay and later route changes', () async {
    final peer = FakePeer();
    final transport = WebRtcGatewayTransport(
      signaling: FakeSignaling(),
      peerFactory: () async => peer,
    );
    addTearDown(transport.close);
    await transport.connect();
    List<StatsReport> reports(String family, String kind) => [
      StatsReport('transport', 'transport', 0, {
        'selectedCandidatePairId': 'p',
      }),
      StatsReport('p', 'candidate-pair', 0, {
        'localCandidateId': 'l',
        'remoteCandidateId': 'r',
      }),
      StatsReport('l', 'local-candidate', 0, {
        'address': family == 'v6' ? '2001:db8::1' : '192.0.2.1',
        'candidateType': 'host',
      }),
      StatsReport('r', 'remote-candidate', 0, {
        'address': family == 'v6' ? '2001:db8::2' : '192.0.2.2',
        'candidateType': kind,
      }),
    ];
    peer.stats = reports('v6', 'host');
    expect(await transport.selectedPathKind(), 'ipv6-direct');
    expect(transport.connectionTraffic.channel, 'ipv6-direct');
    peer.stats = reports('v4', 'host');
    expect(await transport.selectedPathKind(), 'ipv4-direct');
    peer.stats = reports('v6', 'relay');
    expect(await transport.selectedPathKind(), 'relay');
    peer.stats = [];
    expect(await transport.selectedPathKind(), 'unknown');
  });

  test('traffic counts UTF-8 payload fragments while excluding CPG1 headers and close', () async {
    final peer = FakePeer()..channel.autoReply = false;
    final transport = WebRtcGatewayTransport(
      signaling: FakeSignaling(),
      peerFactory: () async => peer,
    );
    addTearDown(transport.close);
    await transport.connect();
    final request = {
      'id': 'traffic',
      'method': 'test',
      'params': {'text': '中文'},
    };
    final pending = transport.request(request);
    await eventually(() => peer.channel.sent.isNotEmpty);
    expect(
      transport.connectionTraffic.sentBytes,
      utf8.encode(jsonEncode(request)).length,
    );
    final response = Uint8List.fromList(
      utf8.encode(
        jsonEncode({'jsonrpc': '2.0', 'id': 'traffic', 'result': '中文'}),
      ),
    );
    peer.channel.onMessage!(
      RTCDataChannelMessage.fromBinary(
        rtcFragment(response.length, 0, response.sublist(0, 10)),
      ),
    );
    expect(transport.connectionTraffic.receivedBytes, 10);
    peer.channel.onMessage!(
      RTCDataChannelMessage.fromBinary(
        rtcFragment(response.length, 10, response.sublist(10)),
      ),
    );
    await pending;
    expect(transport.connectionTraffic.receivedBytes, response.length);
    peer.channel.onMessage!(
      RTCDataChannelMessage.fromBinary(rtcFragment(0, 0, [3, 232])),
    );
    expect(transport.connectionTraffic.receivedBytes, response.length);
  });

  test(
    'heartbeat failure owns liveness after ordinary request timeout',
    () async {
      final peer = FakePeer()..channel.autoReply = false;
      final transport = WebRtcGatewayTransport(
        signaling: FakeSignaling(),
        peerFactory: () async => peer,
        requestTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(transport.close);
      await transport.connect();
      await expectLater(
        transport.request({'id': 'business', 'method': 'conversation.get'}),
        throwsA(isA<GatewayConnectionException>()),
      );
      expect(peer.disposed, isFalse);
      final failed = Completer<void>();
      var sequence = 0;
      final heartbeat = sdk.GatewayHeartbeatClient(
        client: sdk.ProtocolClient(
          transport,
          requestIdFactory: () => 'ping-${sequence++}',
        ),
        interval: const Duration(milliseconds: 10),
        requestTimeout: const Duration(milliseconds: 10),
        failureTimeout: const Duration(milliseconds: 50),
        onProviders: (_) {},
        onFailure: (_, _) {
          failed.complete();
        },
      )..start();
      addTearDown(heartbeat.close);
      await failed.future.timeout(const Duration(seconds: 2));
      // Session owner receives this signal and closes/reconnects the transport.
      await transport.close();
      expect(peer.disposed, isTrue);
    },
  );

  test(
    'slow fragments survive five seconds and sampling stops only on close',
    () async {
      final records = <Map<String, dynamic>>[];
      final logger = Logger('gateway.rtc.diagnostic');
      final logSubscription = logger.onRecord.listen((record) {
        final event = record.object as StructuredLogEvent;
        records.add({'event': event.event, ...event.fields});
      });
      addTearDown(logSubscription.cancel);
      final peer = FakePeer()..channel.autoReply = false;
      final transport = WebRtcGatewayTransport(
        signaling: FakeSignaling(),
        peerFactory: () async => peer,
      );
      final subscription = transport.events.listen(
        (_) {},
        onError: (Object _) {},
      );
      addTearDown(subscription.cancel);
      addTearDown(transport.close);
      await transport.connect();
      expect(transport.requestTimeout, const Duration(seconds: 30));
      final response = transport.request({
        'id': 'slow',
        'method': 'conversation.get',
      });
      final bytes = utf8.encode(
        jsonEncode({'jsonrpc': '2.0', 'id': 'slow', 'result': {}}),
      );
      peer.channel.onMessage!(
        RTCDataChannelMessage.fromBinary(
          rtcFragment(bytes.length, 0, bytes.sublist(0, 3)),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5150));
      expect(peer.disposed, isFalse);
      peer.channel.onMessage!(
        RTCDataChannelMessage.fromBinary(
          rtcFragment(bytes.length, 3, bytes.sublist(3)),
        ),
      );
      expect((await response as Map)['id'], 'slow');
      expect(records.where((r) => r['event'] == 'channel.abort'), isEmpty);
      await transport.close();
      final calls = peer.statsCalls;
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(peer.statsCalls, calls);
      expect(peer.onIceCandidate, isNull);
    },
  );

  test('TLS pin failures stop retries and dispose the native peer', () async {
    final peer = FakePeer();
    final transport = WebRtcGatewayTransport(
      signaling: FakeSignaling(
        failure: const HandshakeException('pin mismatch'),
      ),
      peerFactory: () async => peer,
    );
    await expectLater(
      transport.connect(),
      throwsA(
        isA<GatewayConnectionException>().having(
          (error) => error.retryable,
          'retryable',
          isFalse,
        ),
      ),
    );
    expect(peer.disposed, isTrue);
  });
  test('CPG1 rejects bounds, gaps and interleaving before allocating excess memory', () {
    expect(
      () => RtcDecoder(maximum: 10).push(rtcFragment(11, 0, [1])),
      throwsFormatException,
    );
    expect(
      () => RtcDecoder().push(rtcFragment(2, 1, [1])),
      throwsFormatException,
    );
    final decoder = RtcDecoder();
    expect(decoder.push(rtcFragment(3, 0, [1])), isNull);
    expect(() => decoder.push(rtcFragment(4, 1, [2])), throwsFormatException);
    expect(() => RtcDecoder().push(Uint8List(4)), throwsFormatException);
  });

  test(
    'reliable negotiated channel carries fragmented RPC and unchanged events',
    () async {
      final peer = FakePeer();
      final transport = WebRtcGatewayTransport(
        signaling: FakeSignaling(),
        peerFactory: () async => peer,
      );
      addTearDown(transport.close);
      await transport.connect();
      expect(peer.init!.ordered, isTrue);
      expect(peer.init!.negotiated, isTrue);
      expect(peer.init!.maxRetransmits, -1);
      final event = transport.events.first;
      peer.channel.emit({
        'jsonrpc': '2.0',
        'method': 'test.event',
        'params': {'cursor': '1'},
      });
      expect((await event)['method'], 'test.event');
      final id = '界' * 24000;
      final response = await transport.request({
        'jsonrpc': '2.0',
        'id': id,
        'method': 'provider.list',
        'params': {},
      });
      expect((response as Map)['id'], id);
      expect(((response['result'] as Map)['text'] as String).length, 80000);
      expect(peer.channel.sent.length, greaterThan(4));
      expect(
        peer.channel.sent.every((frame) => frame.length <= rtcFrameBytes),
        isTrue,
      );
    },
  );

  test('native buffered bytes pause sending until low water', () async {
    final peer = FakePeer()..channel.buffer = 100000;
    final transport = WebRtcGatewayTransport(
      signaling: FakeSignaling(),
      peerFactory: () async => peer,
    );
    addTearDown(transport.close);
    await transport.connect();
    final response = transport.request({'id': '1', 'method': 'provider.list'});
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(peer.channel.sent, isEmpty);
    peer.channel.buffer = 0;
    expect((await response as Map)['id'], '1');
  });

  test(
    'responses correlate out of order and close rejects pending without replay',
    () async {
      final peer = FakePeer()..channel.autoReply = false;
      final transport = WebRtcGatewayTransport(
        signaling: FakeSignaling(),
        peerFactory: () async => peer,
      );
      addTearDown(transport.close);
      await transport.connect();
      final first = transport.request({'id': 'a', 'method': 'turn.send'});
      final second = transport.request({'id': 'b', 'method': 'provider.list'});
      final firstFailure = expectLater(
        first,
        throwsA(
          isA<GatewayConnectionException>().having(
            (e) => e.outcomeUnknown,
            'unknown result',
            isTrue,
          ),
        ),
      );
      await eventually(() => peer.channel.sent.length == 2);
      peer.channel.emit({'jsonrpc': '2.0', 'id': 'b', 'result': {}});
      expect((await second as Map)['id'], 'b');
      await transport.close();
      await firstFailure;
      expect(peer.channel.sent.length, 2);
      expect(peer.disposed, isTrue);
    },
  );

  test(
    'timeout preserves a blocked send and subsequent requests still work',
    () async {
      final peer = FakePeer()..channel.blockAfterFirstFrame = true;
      final transport = WebRtcGatewayTransport(
        signaling: FakeSignaling(),
        peerFactory: () async => peer,
        requestTimeout: const Duration(milliseconds: 30),
      );
      final subscription = transport.events.listen(
        (_) {},
        onError: (Object error) =>
            fail('Request timeout leaked to events: $error'),
      );
      addTearDown(subscription.cancel);
      addTearDown(transport.close);
      await transport.connect();
      await expectLater(
        transport.request({
          'id': 'a',
          'method': 'turn.send',
          'params': {'text': 'x' * 40000},
        }),
        throwsA(
          isA<GatewayConnectionException>().having(
            (e) => e.outcomeUnknown,
            'unknown',
            isTrue,
          ),
        ),
      );
      expect(peer.channel.sent, hasLength(1));
      expect(peer.disposed, isFalse);
      peer.channel.buffer = 0;
      await eventually(() => peer.channel.sent.length >= 3);
      final next = await transport.request({
        'id': 'b',
        'method': 'provider.list',
      });
      expect((next as Map)['id'], 'b');
    },
  );

  test(
    'timed out response drains without harming another RPC or events',
    () async {
      final peer = FakePeer()..channel.autoReply = false;
      final transport = WebRtcGatewayTransport(
        signaling: FakeSignaling(),
        peerFactory: () async => peer,
        requestTimeout: const Duration(milliseconds: 80),
      );
      addTearDown(transport.close);
      final errors = <Object>[];
      final events = <Map<String, dynamic>>[];
      final subscription = transport.events.listen(
        events.add,
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      await transport.connect();
      final first = transport.request({
        'id': 'late',
        'method': 'conversation.get',
      });
      final failure = expectLater(
        first,
        throwsA(isA<GatewayConnectionException>()),
      );
      final bytes = utf8.encode(
        jsonEncode({'jsonrpc': '2.0', 'id': 'late', 'result': {}}),
      );
      peer.channel.onMessage!(
        RTCDataChannelMessage.fromBinary(
          rtcFragment(bytes.length, 0, bytes.sublist(0, 5)),
        ),
      );
      await failure;
      final second = transport.request({
        'id': 'live',
        'method': 'protocol.ping',
      });
      peer.channel.onMessage!(
        RTCDataChannelMessage.fromBinary(
          rtcFragment(bytes.length, 5, bytes.sublist(5)),
        ),
      );
      peer.channel.emit({'jsonrpc': '2.0', 'id': 'live', 'result': {}});
      expect((await second as Map)['id'], 'live');
      peer.channel.emit({
        'jsonrpc': '2.0',
        'method': 'test.event',
        'params': {},
      });
      await eventually(() => events.isNotEmpty);
      expect(errors, isEmpty);
      expect(peer.disposed, isFalse);
    },
  );

  test('closing during native peer creation cleans up the late peer', () async {
    final events = <String>[];
    final log = Logger('gateway.rtc.diagnostic').onRecord.listen((record) {
      events.add((record.object as StructuredLogEvent).event);
    });
    addTearDown(log.cancel);
    final native = Completer<RTCPeerConnection>();
    final peer = FakePeer();
    final transport = WebRtcGatewayTransport(
      signaling: FakeSignaling(),
      peerFactory: () => native.future,
    );
    final connection = expectLater(
      transport.connect(),
      throwsA(isA<GatewayConnectionException>()),
    );
    await transport.close();
    native.complete(peer);
    await connection;
    expect(peer.disposed, isTrue);
    expect(events, contains('connect.cancelled'));
    expect(events, isNot(contains('connect.failed')));
  });

  test('a malformed incoming frame aborts the connection', () async {
    final peer = FakePeer();
    final transport = WebRtcGatewayTransport(
      signaling: FakeSignaling(),
      peerFactory: () async => peer,
    );
    final errors = <Object>[];
    final subscription = transport.events.listen((_) {}, onError: errors.add);
    addTearDown(subscription.cancel);
    await transport.connect();
    peer.channel.onMessage!(
      RTCDataChannelMessage.fromBinary(rtcFragment(2, 1, [1])),
    );
    await transport.close();
    expect(errors.single, isA<GatewayConnectionException>());
    expect(peer.disposed, isTrue);
  });
}
