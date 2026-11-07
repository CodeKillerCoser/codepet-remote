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

  /// Null means accepted. The diagnostic and SDP filter share this decision.
  String? rejectionReason(String candidate) {
    if (this == auto) return null;
    final fields = candidate.trim().split(RegExp(r'\s+'));
    if (fields.length < 8 || fields[6] != 'typ') {
      return 'malformed';
    }
    if (fields[2].toLowerCase() != 'udp') return 'nonUdp';
    if (this == relay) return fields[7] == 'relay' ? null : 'nonRelay';
    if (!const {'host', 'srflx', 'prflx'}.contains(fields[7])) {
      return 'nonDirect';
    }
    final address = InternetAddress.tryParse(fields[4]);
    if (address == null) return 'unresolvedAddress';
    if (address.isLoopback) return 'loopback';
    if (address.isLinkLocal) return 'linkLocal';
    if (address.isMulticast) return 'multicast';
    final bytes = address.rawAddress;
    if (bytes.every((b) => b == 0)) return 'unspecified';
    if (this == ipv4Direct) {
      return address.type == InternetAddressType.IPv4 ? null : 'wrongFamily';
    }
    if (address.type != InternetAddressType.IPv6) return 'wrongFamily';
    if (bytes.take(10).every((b) => b == 0) &&
        bytes[10] == 255 &&
        bytes[11] == 255) {
      return 'ipv4Mapped';
    }
    return null;
  }

  String filterSdp(String sdp, {bool allowEmpty = false}) {
    if (this == auto) return sdp;
    var count = 0;
    final lines = sdp.split(RegExp(r'\r?\n')).where((line) {
      if (line.isEmpty || line.startsWith('a=remote-candidates:')) return false;
      if (!line.startsWith('a=candidate:')) return true;
      final accepted = rejectionReason(line) == null;
      if (accepted) count++;
      return accepted;
    }).toList();
    if (count == 0 && !allowEmpty) {
      throw GatewayConnectionException(
        'No ICE candidates for $wireName',
        retryable: true,
      );
    }
    return '${lines.join('\r\n')}\r\n';
  }
}
