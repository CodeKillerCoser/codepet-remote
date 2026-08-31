import 'dart:io';

import 'package:codepet_remote/discovery/codepet_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multicast_dns/multicast_dns.dart';

void main() {
  test('Android mDNS sockets disable unsupported reusePort', () async {
    bool? boundWithReusePort;
    final factory = codePetMdnsSocketFactory(
      isAndroid: true,
      socketBinder: (
        dynamic host,
        int port, {
        bool reuseAddress = true,
        bool reusePort = false,
        int ttl = 1,
      }) {
        boundWithReusePort = reusePort;
        return Future<RawDatagramSocket>.error(StateError('binding observed'));
      },
    );

    await expectLater(
      factory(
        InternetAddress.anyIPv4,
        5353,
        reuseAddress: true,
        reusePort: true,
        ttl: 255,
      ),
      throwsStateError,
    );
    expect(boundWithReusePort, isFalse);
  });

  test('discovery uses the advertised IPv4 record and scopes the multicast lock', () async {
    final client = _FakeMdnsClient();
    final lock = _FakeMulticastLock();
    final discovery = CodePetDiscovery(
      clientFactory: () => client,
      multicastLock: lock,
    );

    final hosts = await discovery.discover().toList();

    expect(hosts, hasLength(1));
    expect(hosts.single.host, '192.0.2.10');
    expect(hosts.single.port, 4321);
    expect(hosts.single.txt['id'], 'trusted-device');
    expect(client.started, isTrue);
    expect(client.stopped, isTrue);
    expect(lock.acquireCalls, 1);
    expect(lock.releaseCalls, 1);
  });

  test('discovery releases the multicast lock when socket startup fails', () async {
    final lock = _FakeMulticastLock();
    final discovery = CodePetDiscovery(
      clientFactory: _FailingMdnsClient.new,
      multicastLock: lock,
    );

    await expectLater(discovery.discover().toList(), throwsStateError);

    expect(lock.acquireCalls, 1);
    expect(lock.releaseCalls, 1);
  });
}

class _FakeMulticastLock implements CodePetMulticastLock {
  int acquireCalls = 0;
  int releaseCalls = 0;

  @override
  Future<void> acquire() async {
    acquireCalls += 1;
  }

  @override
  Future<void> release() async {
    releaseCalls += 1;
  }
}

class _FakeMdnsClient extends MDnsClient {
  static const instance = 'Host._codepet._tcp.local.';
  static const target = 'codepet-host.local.';
  static const validUntil = 4102444800000;

  bool started = false;
  bool stopped = false;

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    started = true;
  }

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final ResourceRecord? record = switch (query.resourceRecordType) {
      ResourceRecordType.serverPointer => const PtrResourceRecord(
          CodePetDiscovery.serviceType,
          validUntil,
          domainName: instance,
        ),
      ResourceRecordType.service => const SrvResourceRecord(
          instance,
          validUntil,
          target: target,
          port: 4321,
          priority: 0,
          weight: 0,
        ),
      ResourceRecordType.text => const TxtResourceRecord(
          instance,
          validUntil,
          text: 'id=trusted-device name=Host vmin=1 vmax=1 pair=0',
        ),
      ResourceRecordType.addressIPv4 => IPAddressResourceRecord(
          target,
          validUntil,
          address: InternetAddress('192.0.2.10'),
        ),
      _ => null,
    };
    return record == null ? Stream<T>.empty() : Stream<T>.value(record as T);
  }

  @override
  void stop() {
    stopped = true;
  }
}

class _FailingMdnsClient extends MDnsClient {
  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    throw StateError('socket startup failed');
  }
}
