import 'dart:convert';

import 'package:codepet_remote/devices/device_registry.dart';
import 'package:codepet_remote/application/ports/device_identity.dart';
import 'package:codepet_remote/application/pairing/pair_device.dart';
import 'package:codepet_remote/application/ports/pairing_gateway.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/pairing/pairing_confirmation.dart';
import 'package:codepet_remote/pairing/pairing_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('pairing confirmation code matches the cross-language vector', () {
    expect(
      derivePairingConfirmationCode(
        requestId: 'request-0123456789abcdef',
        clientNonce: '1234567890abcdef' * 4,
        certificateFingerprint: '0123456789abcdef' * 4,
      ),
      '777533',
    );
  });

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
    final service = PairDeviceUseCase(
      repository: registry,
      descriptorProvider: const _DescriptorProvider(descriptor),
      gateway: LanPairingGateway(exchangeClient: exchange),
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

  test('discovered Host request waits for confirmation then persists credential', () async {
    final credentials = _Credentials();
    final registry = DeviceRegistry(
      metadata: _Metadata(),
      credentials: credentials,
    );
    const descriptor = DeviceDescriptor(
      deviceName: 'Pixel from Android',
      operatingSystem: 'Android',
      systemVersion: '16',
    );
    final exchangeClient = _RequestExchangeClient();
    final service = PairDiscoveredDeviceUseCase(
      repository: registry,
      descriptorProvider: const _DescriptorProvider(descriptor),
      gateway: LanPairingRequestGateway(exchangeClient: exchangeClient),
    );
    const candidate = PairingCandidate(
      deviceId: 'device-host',
      displayName: 'MacBook',
      host: '192.168.1.10',
      port: 49152,
      tlsFingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      hostInitiated: false,
    );

    final pending = await service.request(candidate);
    expect(pending.attempt.state, PairingRequestState.pending);
    expect(pending.attempt.confirmationCode, hasLength(6));
    expect(await registry.load(), isEmpty);
    expect(exchangeClient.createBody?['hostDeviceId'], 'device-host');
    expect(exchangeClient.createBody?['device'], descriptor.toJson());
    expect(exchangeClient.createBody?['clientNonce'],
        matches(RegExp(r'^[0-9a-f]{64}$')));

    final accepted = await service.refresh(pending.attempt);
    expect(accepted.attempt.state, PairingRequestState.accepted);
    expect(accepted.registration?.device.preferredEndpoint,
        'wss://192.168.1.10:49152/remote/v2/gateway');
    final persisted = (await registry.load()).single;
    expect(await credentials.read(persisted.credentialKeyRef!),
        'requested-credential');
    expect(exchangeClient.methods, ['POST', 'GET']);
  });

  test('discovered Host request rejects a relayed confirmation code', () async {
    final service = PairDiscoveredDeviceUseCase(
      repository: DeviceRegistry(
        metadata: _Metadata(),
        credentials: _Credentials(),
      ),
      descriptorProvider: const _DescriptorProvider(
        DeviceDescriptor(
          deviceName: 'Pixel from Android',
          operatingSystem: 'Android',
          systemVersion: '16',
        ),
      ),
      gateway: LanPairingRequestGateway(
        exchangeClient: _RequestExchangeClient(corruptConfirmationCode: true),
      ),
    );
    const candidate = PairingCandidate(
      deviceId: 'device-host',
      displayName: 'MacBook',
      host: '192.168.1.10',
      port: 49152,
      tlsFingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      hostInitiated: false,
    );

    await expectLater(
      service.request(candidate),
      throwsA(isA<FormatException>()),
    );
  });

  test('accepted emulator pairing keeps the Host advertised Gateway URL', () async {
    final registry = DeviceRegistry(
      metadata: _Metadata(),
      credentials: _Credentials(),
    );
    final exchangeClient = _RequestExchangeClient(
      acceptedGatewayUrl:
          'wss://192.168.1.10:47622/remote/v2/gateway',
    );
    final service = PairDiscoveredDeviceUseCase(
      repository: registry,
      descriptorProvider: const _DescriptorProvider(
        DeviceDescriptor(
          deviceName: 'Android Emulator',
          operatingSystem: 'Android',
          systemVersion: '16',
        ),
      ),
      gateway: LanPairingRequestGateway(exchangeClient: exchangeClient),
    );
    const candidate = PairingCandidate(
      deviceId: 'device-host',
      displayName: 'MacBook',
      host: '10.0.2.2',
      port: 47622,
      tlsFingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      hostInitiated: false,
    );

    final pending = await service.request(candidate);
    final accepted = await service.refresh(pending.attempt);

    expect(
      accepted.registration?.device.preferredEndpoint,
      'wss://192.168.1.10:47622/remote/v2/gateway',
    );
  });

  test('accepted pairing rejects an unrelated Gateway host', () async {
    final exchangeClient = _RequestExchangeClient(
      acceptedGatewayUrl: 'wss://unrelated.test:49152/remote/v2/gateway',
    );
    final service = PairDiscoveredDeviceUseCase(
      repository: DeviceRegistry(
        metadata: _Metadata(),
        credentials: _Credentials(),
      ),
      descriptorProvider: const _DescriptorProvider(
        DeviceDescriptor(
          deviceName: 'Pixel from Android',
          operatingSystem: 'Android',
          systemVersion: '16',
        ),
      ),
      gateway: LanPairingRequestGateway(exchangeClient: exchangeClient),
    );
    const candidate = PairingCandidate(
      deviceId: 'device-host',
      displayName: 'MacBook',
      host: '192.168.1.10',
      port: 49152,
      tlsFingerprint:
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      hostInitiated: false,
    );

    final pending = await service.request(candidate);

    await expectLater(
      service.refresh(pending.attempt),
      throwsA(isA<FormatException>()),
    );
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
    required JsonMap? body,
    String method = 'POST',
  }) async {
    expect(method, 'POST');
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

class _RequestExchangeClient implements PairingExchangeClient {
  _RequestExchangeClient({
    this.corruptConfirmationCode = false,
    this.acceptedGatewayUrl =
        'wss://192.168.1.10:49152/remote/v2/gateway',
  });

  final bool corruptConfirmationCode;
  final String acceptedGatewayUrl;
  JsonMap? createBody;
  final List<String> methods = [];
  String? _confirmationCode;

  @override
  Future<JsonMap> exchange({
    required String expectedFingerprint,
    required Uri uri,
    required JsonMap? body,
    String method = 'POST',
  }) async {
    methods.add(method);
    expect(expectedFingerprint, 'a' * 64);
    if (method == 'POST') {
      expect(uri.path, '/remote/v1/pairing-requests');
      createBody = body;
      final nonce = body!['clientNonce']! as String;
      final code = derivePairingConfirmationCode(
        requestId: 'request-one',
        clientNonce: nonce,
        certificateFingerprint: 'a' * 64,
      );
      _confirmationCode = corruptConfirmationCode
          ? '${code.startsWith('0') ? '1' : '0'}${code.substring(1)}'
          : code;
      return _requestResponse(
        'pending',
        confirmationCode: _confirmationCode!,
      );
    }
    expect(uri.path, '/remote/v1/pairing-requests/request-one');
    expect(body, isNull);
    return _requestResponse(
      'accepted',
      confirmationCode: _confirmationCode!,
      gatewayUrl: acceptedGatewayUrl,
      credential: 'requested-credential',
    );
  }
}

JsonMap _requestResponse(
  String state, {
  required String confirmationCode,
  String? gatewayUrl,
  String? credential,
}) {
  final response = <String, dynamic>{
      'requestId': 'request-one',
      'state': state,
      'device': {
        'deviceId': 'device-host',
        'descriptor': {
          'deviceName': 'MacBook',
          'operatingSystem': 'macOS',
          'systemVersion': '15.6',
        },
        'identityFingerprint': 'a' * 64,
      },
      'expiresAt': DateTime.now()
          .toUtc()
          .add(const Duration(minutes: 1))
          .millisecondsSinceEpoch,
      'confirmationCode': confirmationCode,
    };
  if (gatewayUrl != null) response['gatewayUrl'] = gatewayUrl;
  if (credential != null) response['credential'] = credential;
  return response;
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
