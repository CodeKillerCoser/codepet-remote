import 'dart:async';
import 'dart:io';

import 'package:codepet_remote/discovery/codepet_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multicast_dns/multicast_dns.dart';

void main() {
  test('Host directory keeps the latest endpoint for a stable device id', () async {
    final discovery = _StreamingDiscovery();
    final directory = MdnsCodePetHostDirectory(
      discovery: discovery,
      retryDelay: Duration.zero,
    );
    final updates = <DiscoveredCodePetHost>[];
    final advertisements = <DiscoveredCodePetHost>[];
    final subscription = directory.watchHost('trusted-device').listen(updates.add);
    final advertisementSubscription =
        directory.watchHosts().listen(advertisements.add);
    directory.start();
    await pumpEventQueue();

    discovery.controller.add(_discoveredHost('192.168.0.10'));
    await pumpEventQueue();
    discovery.controller.add(_discoveredHost('192.168.0.10', pair: '1'));
    await pumpEventQueue();
    discovery.controller.add(_discoveredHost('192.168.0.11'));
    await pumpEventQueue();

    expect(updates.map((host) => host.host), [
      '192.168.0.10',
      '192.168.0.11',
    ]);
    expect(directory.currentHost('trusted-device')?.host, '192.168.0.11');
    expect(advertisements.map((host) => host.txt['pair']), ['0', '1', '0']);
    expect(directory.currentHosts().single.host, '192.168.0.11');

    await subscription.cancel();
    await advertisementSubscription.cancel();
    await directory.stop();
    await discovery.controller.close();
  });

  test('Host directory does not return an expired endpoint', () async {
    final discovery = _StreamingDiscovery();
    final directory = MdnsCodePetHostDirectory(
      discovery: discovery,
      retryDelay: Duration.zero,
      staleAfter: const Duration(milliseconds: 1),
    );
    directory.start();
    await pumpEventQueue();
    discovery.controller.add(_discoveredHost('192.168.0.10'));
    await pumpEventQueue();
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(directory.currentHost('trusted-device'), isNull);

    await directory.stop();
    await discovery.controller.close();
  });

  test('Host directory refresh clears candidates and starts a new scan', () async {
    final discovery = _RestartableDiscovery();
    final directory = MdnsCodePetHostDirectory(
      discovery: discovery,
      retryDelay: Duration.zero,
    );
    directory.start();
    await pumpEventQueue();
    discovery.controllers.single.add(_discoveredHost('192.168.0.10'));
    await pumpEventQueue();

    expect(directory.currentHosts(), hasLength(1));
    await directory.refresh();
    await pumpEventQueue();

    expect(directory.currentHosts(), isEmpty);
    expect(discovery.discoverCalls, 2);

    await directory.stop();
    for (final controller in discovery.controllers) {
      await controller.close();
    }
  });

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

  test('discovery yields an emulator fallback before mDNS results', () async {
    final client = _FakeMdnsClient();
    final fallback = _discoveredHost('10.0.2.2');
    final discovery = CodePetDiscovery(
      clientFactory: () => client,
      multicastLock: _FakeMulticastLock(),
      fallbackProbe: () async => fallback,
    );

    final hosts = await discovery.discover().toList();

    expect(hosts, hasLength(2));
    expect(hosts.first.host, '10.0.2.2');
    expect(hosts.last.host, '192.0.2.10');
  });

  test('a failed emulator fallback does not prevent mDNS discovery', () async {
    final discovery = CodePetDiscovery(
      clientFactory: _FakeMdnsClient.new,
      multicastLock: _FakeMulticastLock(),
      fallbackProbe: () => Future.error(StateError('probe failed')),
    );

    final hosts = await discovery.discover().toList();

    expect(hosts.single.host, '192.0.2.10');
  });
}

DiscoveredCodePetHost _discoveredHost(
  String address, {
  String pair = '0',
}) => DiscoveredCodePetHost(
      instanceName: 'Host._codepet._tcp.local.',
      host: address,
      port: 47622,
      txt: {
        'id': 'trusted-device',
        'name': 'Host',
        'fp': 'a' * 64,
        'vmin': '1',
        'vmax': '1',
        'pair': pair,
      },
    );

class _StreamingDiscovery extends CodePetDiscovery {
  final StreamController<DiscoveredCodePetHost> controller =
      StreamController<DiscoveredCodePetHost>();

  @override
  Stream<DiscoveredCodePetHost> discover({
    Duration timeout = const Duration(seconds: 4),
  }) => controller.stream;
}

class _RestartableDiscovery extends CodePetDiscovery {
  final List<StreamController<DiscoveredCodePetHost>> controllers = [];
  int discoverCalls = 0;

  @override
  Stream<DiscoveredCodePetHost> discover({
    Duration timeout = const Duration(seconds: 4),
  }) {
    discoverCalls++;
    final controller = StreamController<DiscoveredCodePetHost>();
    controllers.add(controller);
    return controller.stream;
  }
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
          text: 'id=trusted-device name=Host fp=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa vmin=1 vmax=1 pair=0',
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
