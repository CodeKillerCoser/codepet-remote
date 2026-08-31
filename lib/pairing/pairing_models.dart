import 'dart:convert';

import '../gateway/models.dart';
import '../gateway/v1_models.dart';

class PairingQrPayload {
  const PairingQrPayload({required this.version, required this.hostDeviceId, required this.displayName, required this.httpsBaseUrl, required this.certSha256, required this.pairingId, required this.pairingSecret, required this.expiresAt});

  factory PairingQrPayload.parse(String source, {DateTime? now}) {
    final decoded = jsonDecode(source);
    if (decoded is! Map) throw const FormatException('QR payload must be an object');
    final json = Map<String, dynamic>.from(decoded);
    const fields = {'version', 'hostDeviceId', 'displayName', 'httpsBaseUrl', 'certSha256', 'pairingId', 'pairingSecret', 'expiresAt'};
    if (json.keys.toSet().difference(fields).isNotEmpty || fields.difference(json.keys.toSet()).isNotEmpty) throw const FormatException('QR payload fields do not match Gateway v1');
    final version = json['version'];
    final hostDeviceId = _text(json, 'hostDeviceId');
    final displayName = _text(json, 'displayName');
    final baseUrl = Uri.tryParse(_text(json, 'httpsBaseUrl'));
    final fingerprint = _hex64(json, 'certSha256');
    final pairingId = _text(json, 'pairingId');
    final secret = _hex64(json, 'pairingSecret');
    final expiresAtValue = json['expiresAt'];
    if (version != 1) throw const FormatException('Unsupported pairing version');
    if (baseUrl == null || baseUrl.scheme != 'https' || baseUrl.host.isEmpty || baseUrl.userInfo.isNotEmpty || baseUrl.query.isNotEmpty || baseUrl.fragment.isNotEmpty) throw const FormatException('httpsBaseUrl must be a secure HTTPS origin');
    if (baseUrl.path.isNotEmpty && baseUrl.path != '/') throw const FormatException('httpsBaseUrl must not contain a path');
    if (expiresAtValue is! int) throw const FormatException('expiresAt must be an integer timestamp');
    final expiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAtValue, isUtc: true);
    if (!expiresAt.isAfter((now ?? DateTime.now()).toUtc())) throw const FormatException('Pairing QR has expired');
    return PairingQrPayload(version: 1, hostDeviceId: hostDeviceId, displayName: displayName, httpsBaseUrl: baseUrl, certSha256: fingerprint, pairingId: pairingId, pairingSecret: secret, expiresAt: expiresAt);
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

class PairingExchangeResponse {
  const PairingExchangeResponse({required this.device, required this.gatewayUrl, required this.credential});
  factory PairingExchangeResponse.fromJson(JsonMap json) {
    final rawDevice = json['device'];
    if (rawDevice is! Map) throw const FormatException('Missing paired device identity');
    final gatewayUrl = Uri.tryParse(_text(json, 'gatewayUrl'));
    if (gatewayUrl == null || gatewayUrl.scheme != 'wss' || gatewayUrl.host.isEmpty || gatewayUrl.userInfo.isNotEmpty) throw const FormatException('gatewayUrl must use WSS');
    return PairingExchangeResponse(device: V1HostIdentity.fromJson(Map<String, dynamic>.from(rawDevice)), gatewayUrl: gatewayUrl, credential: _text(json, 'credential'));
  }
  final V1HostIdentity device;
  final Uri gatewayUrl;
  final String credential;
}

String _text(JsonMap json, String field) { final value = json[field]; if (value is! String || value.isEmpty) throw FormatException('Invalid $field'); return value; }
String _hex64(JsonMap json, String field) { final value = _text(json, field); if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) throw FormatException('Invalid $field'); return value; }
