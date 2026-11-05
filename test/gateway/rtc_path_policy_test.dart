import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/webrtc/path_policy.dart';

void main() {
  const sdp =
      'v=0\r\na=fingerprint:sha-256 identity\r\n'
      'a=candidate:1 1 udp 1 2001:db8::1 1234 typ host\r\n'
      'a=candidate:2 1 udp 1 192.0.2.1 1234 typ srflx\r\n'
      'a=candidate:3 1 udp 1 192.0.2.2 1234 typ relay\r\n'
      'a=candidate:4 1 udp 1 fe80::1 1234 typ host\r\n'
      'a=candidate:5 1 udp 1 host.local 1234 typ host\r\n';
  test('direct families and relay are disjoint; SDP identity stays intact', () {
    for (final entry in {
      RtcPathPolicy.ipv6Direct: '2001:db8::1',
      RtcPathPolicy.ipv4Direct: '192.0.2.1',
      RtcPathPolicy.relay: '192.0.2.2',
    }.entries) {
      final filtered = entry.key.filterSdp(sdp);
      expect('a=candidate:'.allMatches(filtered), hasLength(1));
      expect(filtered, contains(entry.value));
      expect(filtered, contains('a=fingerprint:sha-256 identity'));
    }
    expect(
      () => RtcPathPolicy.ipv6Direct.filterSdp('v=0\r\n'),
      throwsA(isA<GatewayConnectionException>()),
    );
    expect(RtcPathPolicy.auto.filterSdp(sdp), sdp);
  });
  test('IPv6 avoids servers; IPv4 uses only STUN; relay forces TURN', () {
    final servers = [
      {
        'urls': ['stun:example:3478', 'turn:example:3478'],
        'username': 'test',
        'credential': 'secret',
      },
    ];
    expect(
      RtcPathPolicy.ipv6Direct.configuration(servers)['iceServers'],
      isEmpty,
    );
    expect(
      (RtcPathPolicy.ipv4Direct.configuration(servers)['iceServers'] as List)
          .single['urls'],
      ['stun:example:3478'],
    );
    final relay = RtcPathPolicy.relay.configuration(servers);
    expect(relay['iceTransportPolicy'], 'relay');
    expect((relay['iceServers'] as List).single['urls'], ['turn:example:3478']);
    expect((relay['iceServers'] as List).single['credential'], 'secret');
  });
}
