import 'dart:io';

import '../../application/errors/application_failures.dart';

/// Each cloud attempt negotiates exactly one path. Auto serves legacy callers.
enum RtcPathPolicy {
  auto('auto'),
  ipv6Direct('ipv6-direct'),
  ipv4Direct('ipv4-direct'),
  relay('relay');

  const RtcPathPolicy(this.wireName);
  final String wireName;

  Map<String, dynamic> configuration(List<dynamic> servers) {
    if (this == auto) return {'iceServers': servers};
    final selected = <Map<String, dynamic>>[];
    if (this != ipv6Direct) {
      for (final server in servers.cast<Map>()) {
        final source = server['urls'];
        final urls = (source is String ? [source] : source as List)
            .cast<String>()
            .where(
              (url) => this == relay
                  ? url.startsWith('turn:') || url.startsWith('turns:')
                  : url.startsWith('stun:') || url.startsWith('stuns:'),
            )
            .toList();
        if (urls.isNotEmpty) {
          selected.add({...Map<String, dynamic>.from(server), 'urls': urls});
        }
      }
    }
    return {
      'iceServers': selected,
      'iceTransportPolicy': this == relay ? 'relay' : 'all',
    };
  }

  bool _accepts(String candidate) {
    final fields = candidate.split(RegExp(r'\s+'));
    if (fields.length < 8 ||
        fields[6] != 'typ' ||
        fields[2].toLowerCase() != 'udp') {
      return false;
    }
    if (this == relay) return fields[7] == 'relay';
    if (!const {'host', 'srflx', 'prflx'}.contains(fields[7])) return false;
    final address = InternetAddress.tryParse(fields[4]);
    if (address == null ||
        address.isLoopback ||
        address.isLinkLocal ||
        address.isMulticast) {
      return false;
    }
    final bytes = address.rawAddress;
    if (bytes.every((b) => b == 0)) return false;
    if (this == ipv4Direct) return address.type == InternetAddressType.IPv4;
    return address.type == InternetAddressType.IPv6 &&
        !(bytes.take(10).every((b) => b == 0) &&
            bytes[10] == 255 &&
            bytes[11] == 255);
  }

  String filterSdp(String sdp) {
    if (this == auto) return sdp;
    var count = 0;
    final lines = sdp.split(RegExp(r'\r?\n')).where((line) {
      if (line.isEmpty || line.startsWith('a=remote-candidates:')) return false;
      if (!line.startsWith('a=candidate:')) return true;
      final accepted = _accepts(line);
      if (accepted) count++;
      return accepted;
    }).toList();
    if (count == 0) {
      throw GatewayConnectionException(
        'No ICE candidates for $wireName',
        retryable: true,
      );
    }
    return '${lines.join('\r\n')}\r\n';
  }
}
