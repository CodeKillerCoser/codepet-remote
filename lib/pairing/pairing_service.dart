import '../devices/device_models.dart';
import '../devices/device_registry.dart';
import '../security/pinned_tls.dart';
import 'pairing_models.dart';

class GatewayV1PairingService {
  const GatewayV1PairingService({required this.registry});
  final DeviceRegistry registry;

  Future<PairedDevice> pair(String rawPayload) async {
    final qr = PairingQrPayload.parse(rawPayload);
    final clientId = await registry.loadOrCreateClientId();
    final tls = PinnedTlsConnection(expectedSha256: qr.certSha256);
    final json = await tls.jsonRequest(method: 'POST', uri: qr.exchangeUrl, body: {
      'pairingSecret': qr.pairingSecret,
      'clientId': clientId,
      'clientName': 'CodePet Remote',
      'platform': 'android',
    });
    final response = PairingExchangeResponse.fromJson(json);
    if (response.device.deviceId != qr.hostDeviceId ||
        !constantTimeEquals(response.device.identityFingerprint, qr.certSha256) ||
        response.gatewayUrl.host != qr.httpsBaseUrl.host ||
        response.gatewayUrl.port != qr.httpsBaseUrl.port ||
        response.gatewayUrl.path != '/remote/v1/gateway') {
      throw const FormatException('Pairing identity or endpoint mismatch');
    }
    final credentialKey = 'gateway-v1-credential:${qr.hostDeviceId}:$clientId';
    final device = PairedDevice(
      deviceId: qr.hostDeviceId,
      displayName: response.device.displayName,
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
