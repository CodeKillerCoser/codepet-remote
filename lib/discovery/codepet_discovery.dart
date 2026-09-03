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

abstract interface class CodePetHostDirectory {
  DiscoveredCodePetHost? currentHost(String deviceId);
  List<DiscoveredCodePetHost> currentHosts();
  Stream<DiscoveredCodePetHost> watchHost(String deviceId);
  Stream<DiscoveredCodePetHost> watchHosts();
  void start();
  Future<void> refresh();
  Future<void> stop();
}

class MdnsCodePetHostDirectory implements CodePetHostDirectory {
  MdnsCodePetHostDirectory({
    CodePetDiscovery? discovery,
    this.scanTimeout = const Duration(seconds: 4),
    this.retryDelay = const Duration(milliseconds: 250),
    this.staleAfter = const Duration(seconds: 15),
  }) : discovery = discovery ?? CodePetDiscovery();

  final CodePetDiscovery discovery;
  final Duration scanTimeout;
  final Duration retryDelay;
  final Duration staleAfter;
  final Map<String, _CachedCodePetHost> _hosts = {};
  final StreamController<DiscoveredCodePetHost> _updates =
      StreamController<DiscoveredCodePetHost>.broadcast(sync: true);
  final StreamController<DiscoveredCodePetHost> _advertisements =
      StreamController<DiscoveredCodePetHost>.broadcast(sync: true);
  StreamSubscription<DiscoveredCodePetHost>? _activeScan;
  Completer<void>? _activeScanDone;
  Future<void>? _runner;
  Completer<void>? _stopSignal;
  bool _running = false;

  @override
  DiscoveredCodePetHost? currentHost(String deviceId) {
    final cached = _hosts[deviceId];
    if (cached == null) return null;
    if (DateTime.now().difference(cached.observedAt) > staleAfter) {
      _hosts.remove(deviceId);
      return null;
    }
    return cached.host;
  }

  @override
  List<DiscoveredCodePetHost> currentHosts() {
    final deviceIds = _hosts.keys.toList(growable: false);
    return deviceIds
        .map(currentHost)
        .whereType<DiscoveredCodePetHost>()
        .toList(growable: false);
  }

  @override
  Stream<DiscoveredCodePetHost> watchHost(String deviceId) => _updates.stream
      .where((host) => host.txt['id'] == deviceId);

  @override
  Stream<DiscoveredCodePetHost> watchHosts() => _advertisements.stream;

  @override
  void start() {
    if (_running || _updates.isClosed) return;
    _running = true;
    _stopSignal = Completer<void>();
    _runner = _run(_stopSignal!.future);
  }

  Future<void> _run(Future<void> stopped) async {
    while (_running) {
      final scanDone = Completer<void>();
      final subscription = discovery.discover(timeout: scanTimeout).listen(
        _observe,
        onError: (Object _, StackTrace _) {
          if (!scanDone.isCompleted) scanDone.complete();
        },
        onDone: () {
          if (!scanDone.isCompleted) scanDone.complete();
        },
        cancelOnError: true,
      );
      _activeScan = subscription;
      _activeScanDone = scanDone;
      await Future.any([scanDone.future, stopped]);
      await subscription.cancel();
      if (identical(_activeScan, subscription)) _activeScan = null;
      if (identical(_activeScanDone, scanDone)) _activeScanDone = null;
      if (!_running) break;
      await Future.any([Future<void>.delayed(retryDelay), stopped]);
    }
  }

  void _observe(DiscoveredCodePetHost host) {
    final deviceId = host.txt['id'];
    if (deviceId == null || deviceId.isEmpty) return;
    final previous = _hosts[deviceId]?.host;
    _hosts[deviceId] = _CachedCodePetHost(host, DateTime.now());
    if (!_sameAdvertisement(previous, host) && !_advertisements.isClosed) {
      _advertisements.add(host);
    }
    if (!_sameConnectionCandidate(previous, host) && !_updates.isClosed) {
      _updates.add(host);
    }
  }

  @override
  Future<void> refresh() async {
    if (_updates.isClosed) return;
    _hosts.clear();
    if (!_running) {
      start();
      return;
    }
    final subscription = _activeScan;
    final scanDone = _activeScanDone;
    await subscription?.cancel();
    if (identical(_activeScan, subscription)) _activeScan = null;
    if (scanDone != null && !scanDone.isCompleted) scanDone.complete();
  }

  @override
  Future<void> stop() async {
    if (!_running && _updates.isClosed) return;
    _running = false;
    final stopSignal = _stopSignal;
    if (stopSignal != null && !stopSignal.isCompleted) stopSignal.complete();
    await _activeScan?.cancel();
    _activeScan = null;
    await _runner;
    _runner = null;
    _hosts.clear();
    if (!_updates.isClosed) await _updates.close();
    if (!_advertisements.isClosed) await _advertisements.close();
  }
}

class _CachedCodePetHost {
  const _CachedCodePetHost(this.host, this.observedAt);

  final DiscoveredCodePetHost host;
  final DateTime observedAt;
}

bool _sameConnectionCandidate(
  DiscoveredCodePetHost? left,
  DiscoveredCodePetHost right,
) {
  if (left == null ||
      left.instanceName != right.instanceName ||
      left.host != right.host ||
      left.port != right.port) {
    return false;
  }
  for (final key in const ['id', 'vmin', 'vmax']) {
    if (left.txt[key] != right.txt[key]) return false;
  }
  return true;
}

bool _sameAdvertisement(
  DiscoveredCodePetHost? left,
  DiscoveredCodePetHost right,
) =>
    _sameConnectionCandidate(left, right) &&
    left!.txt['name'] == right.txt['name'] &&
    left.txt['pair'] == right.txt['pair'] &&
    left.txt['fp'] == right.txt['fp'];

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
        const allowed = {'id', 'name', 'fp', 'vmin', 'vmax', 'pair'};
        const required = {'id', 'name', 'vmin', 'vmax', 'pair'};
        if (txt.keys.any((key) => !allowed.contains(key)) || !required.every(txt.containsKey)) continue;
        final fingerprint = txt['fp'];
        if (fingerprint != null &&
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
          continue;
        }
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
