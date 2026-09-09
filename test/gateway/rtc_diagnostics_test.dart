import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:codepet_remote/gateway/webrtc/rtc_diagnostics.dart';

void main() {
  test('candidate summaries retain network clues without SDP secrets', () {
    final value = rtcCandidate(
      'candidate:a 1 udp 123 198.18.0.1 40000 typ host ufrag secret network-id 2',
      'offer',
    );
    expect(value['scope'], 'benchmarkTun');
    expect(value['networkId'], 2);
    expect(value['port'], 40000);
    final encoded = jsonEncode(value);
    expect(encoded, isNot(contains('198.18.0.1')));
    expect(encoded, isNot(contains('secret')));
    expect(
      rtcAddress('198.18.0.1', 'other')['addressId'],
      isNot(value['addressId']),
    );
    expect(rtcCandidate('broken', 'offer')['valid'], isFalse);
  });
  test('stats log only approved fields and keep missing counters missing', () {
    final value = rtcStat(
      StatsReport('pair', 'candidate-pair', 0, {
        'state': 'failed',
        'requestsSent': 3,
        'address': '203.0.113.1',
        'url': 'turn:user:password@host',
        'usernameFragment': 'secret',
        'certificate': 'secret',
        'payload': 'conversation body',
      }),
      'offer',
    );
    expect(value['requestsSent'], 3);
    expect(value.containsKey('responsesReceived'), isFalse);
    final encoded = jsonEncode(value);
    for (final secret in [
      '203.0.113.1',
      'password',
      'secret',
      'conversation body',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });
}
