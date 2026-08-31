import 'dart:convert';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_registry.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry reloads metadata without placing credential in ordinary storage', () async {
    final metadata = _Metadata();
    final credentials = _Credentials();
    final registry = DeviceRegistry(metadata: metadata, credentials: credentials);
    const device = PairedDevice(deviceId: 'host-1', displayName: 'Host', descriptor: DeviceDescriptor(deviceName: 'Host', operatingSystem: 'macOS', systemVersion: '15.6'), tlsFingerprint: 'fingerprint', credentialKeyRef: 'secure:key', clientId: 'client', preferredEndpoint: 'wss://host/remote/v1/gateway', connectionKind: DeviceConnectionKind.pairedGateway);
    await registry.register(device, 'secret-credential');
    final reloaded = await DeviceRegistry(metadata: metadata, credentials: credentials).load();
    expect(reloaded.single.deviceId, 'host-1');
    expect(reloaded.single.descriptor?.systemVersion, '15.6');
    expect(jsonEncode(metadata.values), isNot(contains('secret-credential')));
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
    const first = PairedDevice(deviceId: 'one', displayName: 'One', preferredEndpoint: 'wss://old-one/gateway', connectionKind: DeviceConnectionKind.pairedGateway);
    const second = PairedDevice(deviceId: 'two', displayName: 'Two', preferredEndpoint: 'wss://old-two/gateway', connectionKind: DeviceConnectionKind.pairedGateway);
    await registry.save([first, second]);
    await Future.wait([
      registry.updatePreferredEndpoint('one', 'wss://new-one/gateway'),
      registry.updatePreferredEndpoint('two', 'wss://new-two/gateway'),
    ]);
    final devices = await registry.load();
    expect(devices.map((device) => device.preferredEndpoint), ['wss://new-one/gateway', 'wss://new-two/gateway']);
    final writes = metadata.writeCount;
    await registry.updatePreferredEndpoint('one', 'wss://new-one/gateway');
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
