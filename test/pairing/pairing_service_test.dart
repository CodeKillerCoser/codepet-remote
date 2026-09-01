import 'dart:convert';

import 'package:codepet_remote/devices/device_registry.dart';
import 'package:codepet_remote/devices/local_device_descriptor.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:codepet_remote/pairing/pairing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing sends the stable client id and required device descriptor', () async {
    final metadata = _Metadata();
    final credentials = _Credentials();
    final registry = DeviceRegistry(
      metadata: metadata,
      credentials: credentials,
    );
    final clientId = await registry.loadOrCreateClientId();
    final exchange = _ExchangeClient();
    const descriptor = DeviceDescriptor(
      deviceName: 'Pixel from Android',
      operatingSystem: 'Android',
      systemVersion: '16',
    );
    final service = LanAdmissionService(
      registry: registry,
      descriptorProvider: const _DescriptorProvider(descriptor),
      exchangeClient: exchange,
    );

    final device = await service.pair(_qrPayload());

    expect(exchange.body, {
      'pairingSecret': 'b' * 64,
      'clientId': clientId,
      'device': descriptor.toJson(),
    });
    expect(exchange.body, isNot(contains('clientName')));
    expect(exchange.body, isNot(contains('platform')));
    expect(device.descriptor?.deviceName, 'MacBook');
    expect(device.clientId, clientId);
    expect(await credentials.read(device.credentialKeyRef!), 'opaque-credential');
    final persisted = (await registry.load()).single;
    expect(persisted.deviceId, 'device-host');
    expect(persisted.displayName, 'MacBook');
    expect(persisted.descriptor?.deviceName, 'MacBook');
    expect(persisted.credentialKeyRef, device.credentialKeyRef);
    expect(persisted.preferredEndpoint,
        'wss://192.168.1.10:49152/remote/v2/gateway');
    expect(persisted.autoConnect, isTrue);
    expect(metadata.values.toString(), isNot(contains('opaque-credential')));
  });
}

String _qrPayload() => jsonEncode({
      'version': 1,
      'hostDeviceId': 'device-host',
      'displayName': 'Pairing display',
      'httpsBaseUrl': 'https://192.168.1.10:49152',
      'certSha256': 'a' * 64,
      'pairingId': 'pairing-id',
      'pairingSecret': 'b' * 64,
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch,
    });

class _DescriptorProvider implements DeviceDescriptorProvider {
  const _DescriptorProvider(this.descriptor);

  final DeviceDescriptor descriptor;

  @override
  Future<DeviceDescriptor> load() async => descriptor;
}

class _ExchangeClient implements PairingExchangeClient {
  JsonMap? body;

  @override
  Future<JsonMap> exchange({
    required String expectedFingerprint,
    required Uri uri,
    required JsonMap body,
  }) async {
    expect(expectedFingerprint, 'a' * 64);
    expect(uri.path, '/remote/v1/pairings/pairing-id/exchange');
    this.body = body;
    return {
      'device': {
        'deviceId': 'device-host',
        'descriptor': {
          'deviceName': 'MacBook',
          'operatingSystem': 'macOS',
          'systemVersion': '15.6',
        },
        'identityFingerprint': 'a' * 64,
      },
      'gatewayUrl': 'wss://192.168.1.10:49152/remote/v2/gateway',
      'credential': 'opaque-credential',
    };
  }
}

class _Metadata implements DeviceMetadataStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}

class _Credentials implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }
}
