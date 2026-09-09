import '../../security/pinned_tls.dart';
import '../../application/errors/application_failures.dart';

/// Exchanges descriptions only; implementations never receive business RPC.
abstract interface class RtcSignaling {
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer);
}

abstract interface class RtcIceSignaling implements RtcSignaling {
  Future<Map<String, dynamic>> configuration();
  void close();
}

/// Bootstrap adapter for already paired LAN devices. The TLS pin authenticates
/// the SDP and its ephemeral DTLS fingerprint; bearer authenticates the client.
final class PinnedLanRtcSignaling implements RtcSignaling {
  PinnedLanRtcSignaling({
    required Uri gatewayUri,
    required this.credential,
    required this.certSha256,
  }) : uri = gatewayUri.replace(
         scheme: 'https',
         path: '/remote/v1/webrtc/offer',
         query: '',
         fragment: '',
       ) {
    if (gatewayUri.scheme != 'wss' || gatewayUri.host.isEmpty) {
      throw const FormatException('A paired LAN Gateway endpoint is required');
    }
  }

  final Uri uri;
  final String credential;
  final String certSha256;

  @override
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
    try {
      return await PinnedTlsConnection(
        expectedSha256: certSha256,
      ).jsonRequest(method: 'POST', uri: uri, bearer: credential, body: offer);
    } on PinnedHttpException catch (error) {
      throw GatewayConnectionException(
        'RTC signaling rejected (${error.statusCode})',
        retryable:
            error.statusCode == 408 ||
            error.statusCode == 429 ||
            error.statusCode >= 500,
      );
    }
  }
}
