import 'dart:async';
import 'dart:convert';

import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/devices/device_registry.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry reloads metadata without placing credential in ordinary storage', () async {
    final metadata = _Metadata();
    final credentials = _Credentials();
    final registry = DeviceRegistry(metadata: metadata, credentials: credentials);
    const device = PairedDevice(deviceId: 'host-1', displayName: 'Host', alias: 'Office Host', descriptor: DeviceDescriptor(deviceName: 'Host', operatingSystem: 'macOS', systemVersion: '15.6'), tlsFingerprint: 'fingerprint', endpointHints: ['https://host:443'], credentialKeyRef: 'secure:key', clientId: 'client', preferredEndpoint: 'wss://host/remote/v1/gateway', autoConnect: true, connectionKind: DeviceConnectionKind.pairedGateway);
    await registry.register(device, 'secret-credential');
    final reloaded = await DeviceRegistry(metadata: metadata, credentials: credentials).load();
    expect(reloaded.single.deviceId, 'host-1');
    expect(reloaded.single.alias, 'Office Host');
    expect(reloaded.single.descriptor?.systemVersion, '15.6');
    expect(reloaded.single.endpointHints, ['https://host:443']);
    expect(reloaded.single.credentialKeyRef, 'secure:key');
    expect(reloaded.single.autoConnect, isTrue);
    expect(jsonEncode(metadata.values), isNot(contains('secret-credential')));
    expect(jsonEncode(metadata.values), isNot(contains('conversation')));
    expect(jsonEncode(metadata.values), isNot(contains('message')));
    expect(jsonEncode(metadata.values), isNot(contains('eventCursor')));
    expect(await credentials.read('secure:key'), 'secret-credential');
  });

  test('installation client id is stable', () async {
    final registry = DeviceRegistry(metadata: _Metadata(), credentials: _Credentials());
    final first = await registry.loadOrCreateClientId();
    expect(await registry.loadOrCreateClientId(), first);
  });

  test('forget always removes local metadata and credential', () async {
    final metadata = _Metadata();
    final credentials = _Credentials();
    final registry = DeviceRegistry(metadata: metadata, credentials: credentials);
    const device = PairedDevice(deviceId: 'host-forget', displayName: 'Host', credentialKeyRef: 'secure:forget', clientId: 'client', connectionKind: DeviceConnectionKind.pairedGateway);
    await registry.register(device, 'opaque');
    await registry.forget(device);
    expect(await registry.load(), isEmpty);
    expect(await credentials.read('secure:forget'), isNull);
  });

  test('serializes endpoint updates across devices and skips no-op writes', () async {
    final metadata = _Metadata();
    final registry = DeviceRegistry(metadata: metadata, credentials: _Credentials());
    const first = PairedDevice(deviceId: 'one', displayName: 'One', tlsFingerprint: 'pin-one', endpointHints: ['https://old-one:443'], credentialKeyRef: 'secure:one', clientId: 'client-one', preferredEndpoint: 'wss://old-one/gateway', connectionKind: DeviceConnectionKind.pairedGateway);
    const second = PairedDevice(deviceId: 'two', displayName: 'Two', tlsFingerprint: 'pin-two', clientId: 'client-two', preferredEndpoint: 'wss://old-two/gateway', connectionKind: DeviceConnectionKind.pairedGateway);
    await registry.save([first, second]);
    await Future.wait([
      registry.updatePreferredEndpoint(deviceId: 'one', clientId: 'client-one', tlsFingerprint: 'pin-one', endpoint: 'wss://new-one/gateway'),
      registry.updatePreferredEndpoint(deviceId: 'two', clientId: 'client-two', tlsFingerprint: 'pin-two', endpoint: 'wss://new-two/gateway'),
    ]);
    final devices = await registry.load();
    expect(devices.map((device) => device.preferredEndpoint), ['wss://new-one/gateway', 'wss://new-two/gateway']);
    expect(devices.first.endpointHints, ['https://old-one:443']);
    expect(devices.first.tlsFingerprint, 'pin-one');
    expect(devices.first.credentialKeyRef, 'secure:one');
    expect(devices.first.clientId, 'client-one');
    final writes = metadata.writeCount;
    await registry.updatePreferredEndpoint(deviceId: 'one', clientId: 'client-one', tlsFingerprint: 'pin-one', endpoint: 'wss://new-one/gateway');
    expect(metadata.writeCount, writes);
  });

  test('descriptor refresh keeps the client and certificate binding', () async {
    final metadata = _Metadata();
    final registry = DeviceRegistry(
      metadata: metadata,
      credentials: _Credentials(),
    );
    const paired = PairedDevice(
      deviceId: 'host-bound',
      displayName: 'Old name',
      descriptor: DeviceDescriptor(
        deviceName: 'Old name',
        operatingSystem: 'macOS',
        systemVersion: '15.5',
      ),
      clientId: 'client-bound',
      tlsFingerprint: 'fingerprint-bound',
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    await registry.save([paired]);

    await registry.updateHostDescriptor(
      deviceId: 'host-bound',
      clientId: 'client-bound',
      tlsFingerprint: 'fingerprint-bound',
      descriptor: const DeviceDescriptor(
        deviceName: 'New name',
        operatingSystem: 'macOS',
        systemVersion: '15.6',
      ),
    );
    expect((await registry.load()).single.displayName, 'New name');

    await expectLater(
      registry.updateHostDescriptor(
        deviceId: 'host-bound',
        clientId: 'different-client',
        tlsFingerprint: 'fingerprint-bound',
        descriptor: const DeviceDescriptor(
          deviceName: 'Attacker name',
          operatingSystem: 'Unknown',
          systemVersion: '0',
        ),
      ),
      throwsStateError,
    );
    expect((await registry.load()).single.displayName, 'New name');
  });

  test('endpoint refresh cannot cross a re-paired certificate binding', () async {
    final registry = DeviceRegistry(
      metadata: _Metadata(),
      credentials: _Credentials(),
    );
    const paired = PairedDevice(
      deviceId: 'host-bound',
      displayName: 'Host',
      clientId: 'client-bound',
      tlsFingerprint: 'new-fingerprint',
      preferredEndpoint: 'wss://new-host/remote/v2/gateway',
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    await registry.save([paired]);

    await expectLater(
      registry.updatePreferredEndpoint(
        deviceId: 'host-bound',
        clientId: 'client-bound',
        tlsFingerprint: 'old-fingerprint',
        endpoint: 'wss://stale-host/remote/v2/gateway',
      ),
      throwsStateError,
    );

    expect(
      (await registry.load()).single.preferredEndpoint,
      'wss://new-host/remote/v2/gateway',
    );
  });

  test('forget is ordered after an in-flight endpoint update', () async {
    final metadata = _BlockingMetadata();
    final registry = DeviceRegistry(
      metadata: metadata,
      credentials: _Credentials(),
    );
    const device = PairedDevice(
      deviceId: 'ordered-host',
      displayName: 'Host',
      clientId: 'ordered-client',
      tlsFingerprint: 'ordered-fingerprint',
      preferredEndpoint: 'wss://old/remote/v2/gateway',
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    await registry.save([device]);
    metadata.blockNextWrite();

    final update = registry.updatePreferredEndpoint(
      deviceId: device.deviceId,
      clientId: device.clientId!,
      tlsFingerprint: device.tlsFingerprint!,
      endpoint: 'wss://new/remote/v2/gateway',
    );
    await metadata.writeStarted.future;
    final forget = registry.forget(device);
    metadata.releaseWrite();
    await Future.wait([update, forget]);

    expect(await registry.load(), isEmpty);
  });

  test('failed metadata commit restores the previous credential', () async {
    final metadata = _FailingMetadata();
    final credentials = _Credentials();
    final registry = DeviceRegistry(
      metadata: metadata,
      credentials: credentials,
    );
    const original = PairedDevice(
      deviceId: 'same-host',
      displayName: 'Original',
      credentialKeyRef: 'secure:same-host',
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    await registry.register(original, 'original-credential');
    metadata.failNextWrite = true;

    await expectLater(
      registry.register(
        const PairedDevice(
          deviceId: 'same-host',
          displayName: 'Replacement',
          credentialKeyRef: 'secure:same-host',
          connectionKind: DeviceConnectionKind.pairedGateway,
        ),
        'replacement-credential',
      ),
      throwsStateError,
    );

    expect(await credentials.read('secure:same-host'), 'original-credential');
    expect((await registry.load()).single.displayName, 'Original');
  });

  test('failed metadata read after credential write restores credential', () async {
    final metadata = _ReadFailMetadata();
    final credentials = _Credentials();
    final registry = DeviceRegistry(
      metadata: metadata,
      credentials: credentials,
    );
    const device = PairedDevice(
      deviceId: 'read-failure-host',
      displayName: 'Original',
      credentialKeyRef: 'secure:read-failure',
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    await registry.register(device, 'original-credential');
    metadata.failNextDevicesRead = true;

    await expectLater(
      registry.register(device, 'replacement-credential'),
      throwsStateError,
    );

    expect(
      await credentials.read('secure:read-failure'),
      'original-credential',
    );
  });

  test('credential read failure does not prevent local forgetting', () async {
    final metadata = _Metadata();
    final credentials = _ReadFailCredentials();
    final registry = DeviceRegistry(
      metadata: metadata,
      credentials: credentials,
    );
    const device = PairedDevice(
      deviceId: 'unreadable-host',
      displayName: 'Unreadable',
      credentialKeyRef: 'secure:unreadable',
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    await registry.save([device]);
    await credentials.write('secure:unreadable', 'opaque');

    await registry.forget(device);

    expect(await registry.load(), isEmpty);
    expect(credentials.values, isEmpty);
  });
}

class _Metadata implements DeviceMetadataStore {
  final Map<String, String> values = {};
  int writeCount = 0;
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async { writeCount++; values[key] = value; }
}
class _Credentials implements CredentialStore {
  final Map<String, String> values = {};
  @override Future<void> delete(String key) async { values.remove(key); }
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async { values[key] = value; }
}

class _BlockingMetadata extends _Metadata {
  Completer<void>? _nextWriteRelease;
  Completer<void>? _blockedWriteRelease;
  Completer<void> writeStarted = Completer<void>();

  void blockNextWrite() {
    _nextWriteRelease = Completer<void>();
    writeStarted = Completer<void>();
  }

  void releaseWrite() => _blockedWriteRelease?.complete();

  @override
  Future<void> write(String key, String value) async {
    final release = _nextWriteRelease;
    if (release != null) {
      _nextWriteRelease = null;
      _blockedWriteRelease = release;
      writeStarted.complete();
      await release.future;
      _blockedWriteRelease = null;
    }
    await super.write(key, value);
  }
}

class _FailingMetadata extends _Metadata {
  bool failNextWrite = false;

  @override
  Future<void> write(String key, String value) async {
    if (failNextWrite) {
      failNextWrite = false;
      throw StateError('metadata commit failed');
    }
    await super.write(key, value);
  }
}

class _ReadFailMetadata extends _Metadata {
  bool failNextDevicesRead = false;

  @override
  Future<String?> read(String key) {
    if (key == DeviceRegistry.devicesKey && failNextDevicesRead) {
      failNextDevicesRead = false;
      return Future<String?>.error(StateError('metadata read failed'));
    }
    return super.read(key);
  }
}

class _ReadFailCredentials extends _Credentials {
  @override
  Future<String?> read(String key) =>
      Future<String?>.error(StateError('credential unavailable'));
}
