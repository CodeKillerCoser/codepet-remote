import 'dart:convert';

import 'package:codepet_remote/diagnostics/app_log.dart';
import 'package:codepet_remote/diagnostics/network_environment.dart';
import 'package:codepet_remote/gateway/webrtc/path_policy.dart';
import 'package:codepet_remote/gateway/webrtc/rtc_diagnostics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

final class FakeEnvironment implements NetworkEnvironment {
  FakeEnvironment(this.read);
  final Future<Map<Object?, Object?>> Function() read;
  @override
  Future<Map<Object?, Object?>> snapshot() => read();
}

void main() {
  test('system addresses correlate with candidates without logging addresses or proxy secrets', () async {
    final records = <StructuredLogEvent>[];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen((record) {
      if (record.object case final StructuredLogEvent event) records.add(event);
    });
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previous;
    });
    final diagnostics = RtcDiagnostics(
      raceId: 'race',
      networkEnvironment: FakeEnvironment(
        () async => {
          'source': 'androidConnectivityManager',
          'defaultNetwork': '42',
          'httpProxyConfigured': true,
          'proxyPassword': 'secret',
          'networks': [
            {
              'network': '42',
              'transports': ['vpn', 'cellular'],
              'isDefault': true,
              'addresses': [
                {'address': '2001:db8:0:0:0:0:0:1', 'prefixLength': 64},
              ],
              'routes': [
                {'family': 'IPv6', 'isDefault': true, 'gateway': 'secret'},
              ],
            },
          ],
        },
      ),
    );
    await diagnostics.networkSnapshot('raceStart');
    final snapshot = records.single;
    final network = (snapshot.fields['networks'] as List).single as Map;
    final address = (network['addresses'] as List).single as Map;
    final candidate = diagnostics.candidateDecision(
      'candidate:1 1 udp 1 2001:db8::1 1234 typ host ufrag secret',
      RtcPathPolicy.ipv6Direct,
    );
    expect(candidate['networkAddressId'], address['networkAddressId']);
    expect(candidate['accepted'], true);
    expect(network['transports'], ['vpn', 'cellular']);
    final encoded = jsonEncode([snapshot.fields, candidate]);
    expect(encoded, isNot(contains('2001:db8')));
    expect(encoded, isNot(contains('secret')));
  });

  test(
    'unavailable platform inspection cannot fail connection diagnostics',
    () async {
      final diagnostics = RtcDiagnostics(
        networkEnvironment: FakeEnvironment(
          () async => throw StateError('private native error'),
        ),
      );
      await expectLater(diagnostics.networkSnapshot('raceStart'), completes);
    },
  );

  test('filter reasons describe the actual SDP decisions', () {
    const cases = {
      '2001:db8::1': null,
      'fd00::1': null, // Private VPN IPv6 is allowed, not assumed unusable.
      '192.0.2.1': 'wrongFamily',
      '::1': 'loopback',
      'fe80::1': 'linkLocal',
      '::': 'unspecified',
      'ff02::1': 'multicast',
      '::ffff:192.0.2.1': 'ipv4Mapped',
    };
    for (final entry in cases.entries) {
      final candidate = 'a=candidate:1 1 udp 1 ${entry.key} 1234 typ host';
      expect(RtcPathPolicy.ipv6Direct.rejectionReason(candidate), entry.value);
      if (entry.value == null) {
        expect(
          RtcPathPolicy.ipv6Direct.filterSdp('v=0\r\n$candidate\r\n'),
          contains(candidate),
        );
      } else {
        expect(
          () => RtcPathPolicy.ipv6Direct.filterSdp('v=0\r\n$candidate\r\n'),
          throwsException,
        );
      }
    }
  });

  test('stable counters are sampled every 30s but topology changes and closing are immediate', () {
    final policy = RtcStatsLogPolicy();
    final report = <String, Object?>{
      'id': 'p',
      'type': 'candidate-pair',
      'state': 'succeeded',
      'bytesSent': 1,
    };
    expect(policy.shouldEmit([report], 0), true);
    report['bytesSent'] = 500;
    expect(policy.shouldEmit([report], 2000), false);
    expect(policy.shouldEmit([report], 30000), true);
    report['state'] = 'failed';
    expect(policy.shouldEmit([report], 30001), true);
    expect(policy.shouldEmit([report], 30002, force: true), true);
  });
}
