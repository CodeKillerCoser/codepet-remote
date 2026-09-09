import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/webrtc/framing.dart';
import 'package:codepet_remote/gateway/webrtc/signaling.dart';
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

class FakePeer extends RTCPeerConnection {
  final channel = FakeChannel();
  RTCDataChannelInit? init;
  bool disposed = false;
  int statsCalls = 0;
  @override
  Future<List<StatsReport>> getStats([MediaStreamTrack? track]) async {
    statsCalls++;
    return [
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
    'fragment timeout logs partial progress and stops ICE sampling on close',
    () async {
      final records = <Map<String, dynamic>>[];
      final logger = Logger('gateway.rtc.diagnostic');
      final logSubscription = logger.onRecord.listen((record) {
        records.add(jsonDecode(record.message) as Map<String, dynamic>);
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
      peer.channel.onMessage!(
        RTCDataChannelMessage.fromBinary(rtcFragment(100, 0, [1, 2, 3])),
      );
      await Future<void>.delayed(const Duration(milliseconds: 5150));
      await transport.close();
      final abort = records.singleWhere((r) => r['event'] == 'channel.abort');
      expect(abort['cause'], 'fragmentTimeout');
      expect(abort['partialReceived'], 3);
      expect(abort['partialTotal'], 100);
      expect(abort['lastFragmentAgeMs'], greaterThanOrEqualTo(4900));
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
    'timeout aborts an unfinished send and reports unknown outcome',
    () async {
      final peer = FakePeer()..channel.buffer = 100000;
      final transport = WebRtcGatewayTransport(
        signaling: FakeSignaling(),
        peerFactory: () async => peer,
        requestTimeout: const Duration(milliseconds: 30),
      );
      final subscription = transport.events.listen(
        (_) {},
        onError: (Object _) {},
      );
      addTearDown(subscription.cancel);
      addTearDown(transport.close);
      await transport.connect();
      await expectLater(
        transport.request({'id': 'a', 'method': 'turn.send'}),
        throwsA(
          isA<GatewayConnectionException>().having(
            (e) => e.outcomeUnknown,
            'unknown',
            isTrue,
          ),
        ),
      );
      await transport.close();
      expect(peer.channel.sent, isEmpty);
      expect(peer.disposed, isTrue);
    },
  );

  test('closing during native peer creation cleans up the late peer', () async {
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
