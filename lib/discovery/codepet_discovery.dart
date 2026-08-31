import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

class DiscoveredCodePetHost {
  const DiscoveredCodePetHost({required this.instanceName, required this.host, required this.port, required this.txt});
  final String instanceName;
  final String host;
  final int port;
  final Map<String, String> txt;
}

class CodePetDiscovery {
  static const serviceType = '_codepet._tcp.local';

  Stream<DiscoveredCodePetHost> discover({Duration timeout = const Duration(seconds: 4)}) async* {
    final client = MDnsClient();
    await client.start();
    try {
      final pointers = client.lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(serviceType)).timeout(timeout);
      await for (final pointer in pointers) {
        SrvResourceRecord? service;
        await for (final record in client.lookup<SrvResourceRecord>(ResourceRecordQuery.service(pointer.domainName)).timeout(timeout)) {
          service = record;
          break;
        }
        if (service == null) continue;
        final txt = <String, String>{};
        await for (final record in client.lookup<TxtResourceRecord>(ResourceRecordQuery.text(pointer.domainName)).timeout(timeout)) {
          for (final entry in record.text.split(RegExp(r'\s+'))) {
            final separator = entry.indexOf('=');
            if (separator > 0) txt[entry.substring(0, separator)] = entry.substring(separator + 1);
          }
          break;
        }
        const allowed = {'id', 'name', 'vmin', 'vmax', 'pair'};
        if (txt.keys.any((key) => !allowed.contains(key)) || !allowed.every(txt.containsKey)) continue;
        yield DiscoveredCodePetHost(instanceName: pointer.domainName, host: service.target, port: service.port, txt: txt);
      }
    } finally {
      client.stop();
    }
  }
}
