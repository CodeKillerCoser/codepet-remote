import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

class DiscoveredCodePetHost {
  const DiscoveredCodePetHost({required this.instanceName, required this.host, required this.port, required this.txt});
  final String instanceName;
  final String host;
  final int port;
  final Map<String, String> txt;
}

abstract interface class CodePetMulticastLock {
  Future<void> acquire();
  Future<void> release();
}

class PlatformCodePetMulticastLock implements CodePetMulticastLock {
  static const MethodChannel _channel = MethodChannel('com.codepet.remote/mdns');

  @override
  Future<void> acquire() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('acquireMulticastLock');
  }

  @override
  Future<void> release() async {
    if (Platform.isAndroid) await _channel.invokeMethod<void>('releaseMulticastLock');
  }
}

RawDatagramSocketFactory codePetMdnsSocketFactory({
  required bool isAndroid,
  RawDatagramSocketFactory socketBinder = RawDatagramSocket.bind,
}) => (
  dynamic host,
  int port, {
  bool reuseAddress = true,
  bool reusePort = false,
  int ttl = 1,
}) => socketBinder(
  host,
  port,
  reuseAddress: reuseAddress,
  reusePort: isAndroid ? false : reusePort,
  ttl: ttl,
);

class CodePetDiscovery {
  CodePetDiscovery({
    MDnsClient Function()? clientFactory,
    CodePetMulticastLock? multicastLock,
  })  : _clientFactory = clientFactory ?? _defaultClient,
        _multicastLock = multicastLock ?? PlatformCodePetMulticastLock();

  static const serviceType = '_codepet._tcp.local.';
  final MDnsClient Function() _clientFactory;
  final CodePetMulticastLock _multicastLock;

  static MDnsClient _defaultClient() => MDnsClient(
    rawDatagramSocketFactory: codePetMdnsSocketFactory(
      isAndroid: Platform.isAndroid,
    ),
  );

  Stream<DiscoveredCodePetHost> discover({Duration timeout = const Duration(seconds: 4)}) async* {
    final client = _clientFactory();
    var started = false;
    await _multicastLock.acquire();
    try {
      await client.start();
      started = true;
      final pointers = client.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer(serviceType),
        timeout: timeout,
      );
      await for (final pointer in pointers) {
        final service = await _first(client.lookup<SrvResourceRecord>(
          ResourceRecordQuery.service(pointer.domainName),
          timeout: timeout,
        ));
        if (service == null) continue;
        final txt = <String, String>{};
        final text = await _first(client.lookup<TxtResourceRecord>(
          ResourceRecordQuery.text(pointer.domainName),
          timeout: timeout,
        ));
        if (text != null) {
          for (final entry in text.text.split(RegExp(r'\s+'))) {
            final separator = entry.indexOf('=');
            if (separator > 0) txt[entry.substring(0, separator)] = entry.substring(separator + 1);
          }
        }
        const allowed = {'id', 'name', 'vmin', 'vmax', 'pair'};
        if (txt.keys.any((key) => !allowed.contains(key)) || !allowed.every(txt.containsKey)) continue;
        final address = await _first(client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(service.target),
          timeout: timeout,
        ));
        yield DiscoveredCodePetHost(
          instanceName: pointer.domainName,
          host: address?.address.address ?? service.target,
          port: service.port,
          txt: txt,
        );
      }
    } finally {
      if (started) client.stop();
      await _multicastLock.release();
    }
  }
}

Future<T?> _first<T>(Stream<T> values) async {
  await for (final value in values) {
    return value;
  }
  return null;
}
