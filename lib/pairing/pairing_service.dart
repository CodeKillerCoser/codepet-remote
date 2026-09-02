import '../devices/device_models.dart';
import '../devices/device_registry.dart';
import '../devices/local_device_descriptor.dart';
import '../core/domain/models.dart';
import '../security/pinned_tls.dart';
import 'pairing_models.dart';
import 'package:codepet_lan_channel_sdk/codepet_lan_channel_sdk.dart' as sdk;

abstract interface class PairingExchangeClient {
  Future<JsonMap> exchange({
    required String expectedFingerprint,
    required Uri uri,
    required JsonMap body,
  });
}

class PinnedPairingExchangeClient implements PairingExchangeClient {
  const PinnedPairingExchangeClient();

  @override
  Future<JsonMap> exchange({
    required String expectedFingerprint,
    required Uri uri,
    required JsonMap body,
  }) =>
      PinnedTlsConnection(expectedSha256: expectedFingerprint).jsonRequest(
        method: 'POST',
        uri: uri,
        body: body,
      );
}

class LanAdmissionService {
  LanAdmissionService({
    required this.registry,
    DeviceDescriptorProvider? descriptorProvider,
    this.exchangeClient = const PinnedPairingExchangeClient(),
  }) : descriptorProvider =
            descriptorProvider ?? LocalDeviceDescriptorProvider();

  final DeviceRegistry registry;
  final DeviceDescriptorProvider descriptorProvider;
  final PairingExchangeClient exchangeClient;

  Future<PairedDevice> pair(String rawPayload) async {
    final qr = PairingQrPayload.parse(rawPayload);
    final clientId = await registry.loadOrCreateClientId();
    final descriptor = await descriptorProvider.load();
    final json = await exchangeClient.exchange(
      expectedFingerprint: qr.certSha256,
      uri: qr.exchangeUrl,
      body: sdk.PairingExchangeRequest.fromJson({
        'pairingSecret': qr.pairingSecret,
        'clientId': clientId,
        'device': descriptor.toJson(),
      }).toJson(),
    );
    final response = PairingExchangeResponse.fromJson(json);
    if (response.device.deviceId != qr.hostDeviceId ||
        !constantTimeEquals(
          response.device.identityFingerprint,
          qr.certSha256,
        ) ||
        response.gatewayUrl.host != qr.httpsBaseUrl.host ||
        response.gatewayUrl.port != qr.httpsBaseUrl.port ||
        response.gatewayUrl.path != '/remote/v2/gateway') {
      throw const FormatException('Pairing identity or endpoint mismatch');
    }
    final credentialKey =
        'gateway-v1-credential:${qr.hostDeviceId}:$clientId';
    final device = PairedDevice(
      deviceId: qr.hostDeviceId,
      displayName: response.device.descriptor.deviceName,
      descriptor: response.device.descriptor,
      tlsFingerprint: qr.certSha256,
      endpointHints: [qr.httpsBaseUrl.toString()],
      credentialKeyRef: credentialKey,
      clientId: clientId,
      preferredEndpoint: response.gatewayUrl.toString(),
      autoConnect: true,
      connectionKind: DeviceConnectionKind.pairedGateway,
    );
    await registry.register(device, response.credential);
    return device;
  }
}
