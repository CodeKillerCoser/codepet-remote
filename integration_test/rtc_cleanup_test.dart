import 'dart:async';

import 'package:codepet_remote/diagnostics/app_log.dart';
import 'package:codepet_remote/gateway/webrtc/signaling.dart';
import 'package:codepet_remote/gateway/webrtc/webrtc_gateway_transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logging/logging.dart';

/// Exercises real native peer/channel creation and disposal without a paired
/// device or external server. Network switching and TURN require separate tests.
class _WaitingSignaling implements RtcTrickleSignaling {
  final offered = Completer<void>();
  final _answer = Completer<Map<String, dynamic>>();
  @override
  bool get trickleEnabled => true;
  @override
  Future<Map<String, dynamic>> configuration() async => {'iceServers': []};
  @override
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) {
    offered.complete();
    return _answer.future;
  }

  @override
  void close() {
    if (!_answer.isCompleted) _answer.complete({});
  }

  @override
  void localCandidate(Map<String, dynamic>? candidate) {}
  @override
  void checkTrickleFailure() {}
  @override
  void finishTrickle() {}
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native cancellation and repeated disposal acknowledge every peer',
    (tester) async {
      final events = <StructuredLogEvent>[];
      final logs = Logger('gateway.rtc.diagnostic').onRecord.listen((record) {
        if (record.object case final StructuredLogEvent event) {
          events.add(event);
        }
      });
      addTearDown(logs.cancel);
      await tester.runAsync(() async {
        for (var round = 0; round < 20; round++) {
          await Future.wait(
            List.generate(2, (index) async {
              final signaling = _WaitingSignaling();
              final created = Completer<void>(), gate = Completer<void>();
              final transport = WebRtcGatewayTransport(
                signaling: signaling,
                peerFactory: () async {
                  final peer = await createPeerConnection({'iceServers': []});
                  created.complete();
                  if (index == 0) await gate.future;
                  return peer;
                },
              );
              final connecting = expectLater(
                transport.connect(),
                throwsException,
              );
              if (index == 0) {
                await created.future.timeout(const Duration(seconds: 10));
                final closing = transport.close();
                gate.complete();
                await closing;
              } else {
                await signaling.offered.future.timeout(
                  const Duration(seconds: 10),
                );
                await transport.close();
              }
              await connecting;
            }),
          );
        }
      });
      expect(events.where((e) => e.event == 'cleanup.failed'), isEmpty);
      expect(
        events.where((e) => e.event == 'cleanup.completed'),
        hasLength(40),
      );
    },
  );
}
