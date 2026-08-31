import 'dart:convert';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_registry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registry reloads metadata without placing credential in ordinary storage', () async {
    final metadata = _Metadata();
    final credentials = _Credentials();
    final registry = DeviceRegistry(metadata: metadata, credentials: credentials);
    const device = PairedDevice(deviceId: 'host-1', displayName: 'Host', tlsFingerprint: 'fingerprint', credentialKeyRef: 'secure:key', clientId: 'client', preferredEndpoint: 'wss://host/remote/v1/gateway', connectionKind: DeviceConnectionKind.pairedGateway);
    await registry.register(device, 'secret-credential');
    final reloaded = await DeviceRegistry(metadata: metadata, credentials: credentials).load();
    expect(reloaded.single.deviceId, 'host-1');
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
}

class _Metadata implements DeviceMetadataStore {
  final Map<String, String> values = {};
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async { values[key] = value; }
}
class _Credentials implements CredentialStore {
  final Map<String, String> values = {};
  @override Future<void> delete(String key) async { values.remove(key); }
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async { values[key] = value; }
}
