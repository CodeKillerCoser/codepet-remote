import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../security/pinned_tls.dart';

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

class PlatformCodePetNsdDiscovery {
  static const MethodChannel _channel = MethodChannel('com.codepet.remote/mdns');

  Future<List<DiscoveredCodePetHost>> discover(Duration timeout) async {
    final records = await _channel.invokeMethod<List<dynamic>>(
      'discoverServices',
      {
        'serviceType': '_codepet._tcp.',
        'timeoutMillis': timeout.inMilliseconds,
      },
    );
    if (records == null) return const [];
    return records
        .map(_decodeRecord)
        .whereType<DiscoveredCodePetHost>()
        .toList(growable: false);
  }

  DiscoveredCodePetHost? _decodeRecord(dynamic record) {
    if (record is! Map) return null;
    final map = Map<String, dynamic>.from(record);
    final rawTxt = map['txt'];
    if (rawTxt is! Map) return null;
    final txt = rawTxt.map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    );
    return validatedDiscoveredCodePetHost(
      instanceName: map['instanceName'],
      host: map['host'],
      port: map['port'],
      txt: txt,
    );
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
    this._fallbackProbe,
    Future<List<DiscoveredCodePetHost>> Function(Duration)? nativeDiscovery,
  })  : _clientFactory = clientFactory ?? _defaultClient,
        _multicastLock = multicastLock ?? PlatformCodePetMulticastLock(),
        _nativeDiscovery = nativeDiscovery ??
            (Platform.isAndroid
                ? PlatformCodePetNsdDiscovery().discover
                : null);

  static const serviceType = '_codepet._tcp.local.';
  final MDnsClient Function() _clientFactory;
  final CodePetMulticastLock _multicastLock;
  final Future<DiscoveredCodePetHost?> Function()? _fallbackProbe;
  final Future<List<DiscoveredCodePetHost>> Function(Duration)?
      _nativeDiscovery;

  static MDnsClient _defaultClient() => MDnsClient(
    rawDatagramSocketFactory: codePetMdnsSocketFactory(
      isAndroid: Platform.isAndroid,
    ),
  );

  Stream<DiscoveredCodePetHost> discover({Duration timeout = const Duration(seconds: 4)}) async* {
    final fallbackProbe = _fallbackProbe;
    if (fallbackProbe != null) {
      try {
        final fallback = await fallbackProbe().timeout(timeout);
        if (fallback != null) yield fallback;
      } catch (_) {}
    }
    final nativeDiscovery = _nativeDiscovery;
    if (nativeDiscovery != null) {
      try {
        final hosts = await nativeDiscovery(timeout).timeout(
          timeout + const Duration(milliseconds: 500),
        );
        if (hosts.isNotEmpty) {
          yield* Stream<DiscoveredCodePetHost>.fromIterable(hosts);
          return;
        }
      } catch (_) {}
    }
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
        final address = await _first(client.lookup<IPAddressResourceRecord>(
          ResourceRecordQuery.addressIPv4(service.target),
          timeout: timeout,
        ));
        final host = validatedDiscoveredCodePetHost(
          instanceName: pointer.domainName,
          host: address?.address.address ?? service.target,
          port: service.port,
          txt: txt,
        );
        if (host != null) yield host;
      }
    } finally {
      if (started) client.stop();
      await _multicastLock.release();
    }
  }
}

DiscoveredCodePetHost? validatedDiscoveredCodePetHost({
  required dynamic instanceName,
  required dynamic host,
  required dynamic port,
  required Map<String, String> txt,
}) {
  const allowed = {'id', 'name', 'fp', 'vmin', 'vmax', 'pair'};
  const required = {'id', 'name', 'vmin', 'vmax', 'pair'};
  if (instanceName is! String ||
      instanceName.isEmpty ||
      host is! String ||
      host.isEmpty ||
      port is! int ||
      port < 1 ||
      port > 65535 ||
      txt.keys.any((key) => !allowed.contains(key)) ||
      !required.every(txt.containsKey)) {
    return null;
  }
  final fingerprint = txt['fp'];
  final minimumVersion = int.tryParse(txt['vmin'] ?? '');
  final maximumVersion = int.tryParse(txt['vmax'] ?? '');
  if ((fingerprint != null &&
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) ||
      minimumVersion == null ||
      minimumVersion < 1 ||
      maximumVersion == null ||
      maximumVersion < minimumVersion ||
      (txt['pair'] != '0' && txt['pair'] != '1') ||
      txt['id']!.isEmpty ||
      txt['name']!.isEmpty) {
    return null;
  }
  return DiscoveredCodePetHost(
    instanceName: instanceName,
    host: host,
    port: port,
    txt: txt,
  );
}

class AndroidEmulatorCodePetHostProbe {
  AndroidEmulatorCodePetHostProbe({
    Uri? endpoint,
    this.timeout = const Duration(seconds: 2),
  }) : endpoint = endpoint ??
            Uri(
              scheme: 'https',
              host: '10.0.2.2',
              port: 47622,
              path: '/remote/v1/discovery',
            );

  final Uri endpoint;
  final Duration timeout;

  Future<DiscoveredCodePetHost?> probe() async {
    String? presentedFingerprint;
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    )..connectionTimeout = timeout;
    client.badCertificateCallback = (certificate, host, port) {
      if (host != endpoint.host || port != endpoint.port) return false;
      presentedFingerprint = certificateSha256(certificate);
      return true;
    };
    try {
      final request = await client.getUrl(endpoint).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, ContentType.json.mimeType);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) return null;
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > 64 * 1024) return null;
        bytes.addAll(chunk);
      }
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return null;
      final json = Map<String, dynamic>.from(decoded);
      const fields = {'id', 'name', 'fp', 'vmin', 'vmax', 'pair'};
      if (json.keys.toSet().difference(fields).isNotEmpty ||
          !fields.every(json.containsKey)) {
        return null;
      }
      final id = json['id'];
      final name = json['name'];
      final fingerprint = json['fp'];
      final minimumVersion = json['vmin'];
      final maximumVersion = json['vmax'];
      final pairingAvailable = json['pair'];
      if (id is! String ||
          id.isEmpty ||
          name is! String ||
          name.isEmpty ||
          fingerprint is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint) ||
          presentedFingerprint != fingerprint ||
          minimumVersion is! int ||
          maximumVersion is! int ||
          minimumVersion < 1 ||
          maximumVersion < minimumVersion ||
          pairingAvailable is! int ||
          pairingAvailable < 0 ||
          pairingAvailable > 1) {
        return null;
      }
      return DiscoveredCodePetHost(
        instanceName: '$name (Android Emulator)',
        host: endpoint.host,
        port: endpoint.port,
        txt: {
          'id': id,
          'name': name,
          'fp': fingerprint,
          'vmin': minimumVersion.toString(),
          'vmax': maximumVersion.toString(),
          'pair': pairingAvailable.toString(),
        },
      );
    } finally {
      client.close(force: true);
    }
  }
}

Future<T?> _first<T>(Stream<T> values) async {
  await for (final value in values) {
    return value;
  }
  return null;
}
