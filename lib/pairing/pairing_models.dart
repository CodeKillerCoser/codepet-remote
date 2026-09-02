import 'dart:convert';

import 'package:codepet_lan_channel_sdk/codepet_lan_channel_sdk.dart' as sdk;

import '../core/domain/models.dart';

/// App-facing view of the generated LAN admission QR model.
class PairingQrPayload {
  const PairingQrPayload({required this.version, required this.hostDeviceId, required this.displayName, required this.httpsBaseUrl, required this.certSha256, required this.pairingId, required this.pairingSecret, required this.expiresAt});

  factory PairingQrPayload.parse(String source, {DateTime? now}) {
    final sdk.PairingQrPayload generated;
    try {
      generated = sdk.PairingQrPayload.fromJson(jsonDecode(source));
    } on sdk.ProtocolCodecException catch (error) {
      throw FormatException(error.toString());
    }
    final baseUrl = Uri.tryParse(generated.httpsBaseUrl);
    if (baseUrl == null || baseUrl.scheme != 'https' || baseUrl.host.isEmpty || baseUrl.userInfo.isNotEmpty || baseUrl.query.isNotEmpty || baseUrl.fragment.isNotEmpty) throw const FormatException('httpsBaseUrl must be a secure HTTPS origin');
    if (baseUrl.path.isNotEmpty && baseUrl.path != '/') throw const FormatException('httpsBaseUrl must not contain a path');
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(generated.expiresAt, isUtc: true);
    if (!expiresAt.isAfter((now ?? DateTime.now()).toUtc())) throw const FormatException('Pairing QR has expired');
    return PairingQrPayload(version: generated.version, hostDeviceId: generated.hostDeviceId, displayName: generated.displayName, httpsBaseUrl: baseUrl, certSha256: generated.certSha256, pairingId: generated.pairingId, pairingSecret: generated.pairingSecret, expiresAt: expiresAt);
  }

  final int version;
  final String hostDeviceId;
  final String displayName;
  final Uri httpsBaseUrl;
  final String certSha256;
  final String pairingId;
  final String pairingSecret;
  final DateTime expiresAt;

  Uri get exchangeUrl => httpsBaseUrl.replace(path: '/remote/v1/pairings/${Uri.encodeComponent(pairingId)}/exchange');
}

class PairingHostIdentity {
  const PairingHostIdentity({required this.deviceId, required this.descriptor, required this.identityFingerprint});

  final String deviceId;
  final DeviceDescriptor descriptor;
  final String identityFingerprint;
}

class PairingExchangeResponse {
  const PairingExchangeResponse({required this.device, required this.gatewayUrl, required this.credential});

  factory PairingExchangeResponse.fromJson(JsonMap json) {
    final sdk.PairingExchangeResponse generated;
    try {
      generated = sdk.PairingExchangeResponse.fromJson(json);
    } on sdk.ProtocolCodecException catch (error) {
      throw FormatException(error.toString());
    }
    final gatewayUrl = Uri.tryParse(generated.gatewayUrl);
    if (gatewayUrl == null || gatewayUrl.scheme != 'wss' || gatewayUrl.host.isEmpty || gatewayUrl.userInfo.isNotEmpty || gatewayUrl.query.isNotEmpty || gatewayUrl.fragment.isNotEmpty) throw const FormatException('gatewayUrl must use WSS');
    return PairingExchangeResponse(
      device: PairingHostIdentity(
        deviceId: generated.device.deviceId,
        descriptor: DeviceDescriptor.fromJson(Map<String, dynamic>.from(generated.device.descriptor.toJson())),
        identityFingerprint: generated.device.identityFingerprint,
      ),
      gatewayUrl: gatewayUrl,
      credential: generated.credential,
    );
  }

  final PairingHostIdentity device;
  final Uri gatewayUrl;
  final String credential;
}
