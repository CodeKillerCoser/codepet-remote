import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

class PinnedTlsConnection {
  const PinnedTlsConnection({required this.expectedSha256});
  final String expectedSha256;

  Future<SecureSocket> connect(Uri uri) async {
    if (uri.scheme != 'https' && uri.scheme != 'wss') throw const FormatException('TLS endpoint required');
    final socket = await SecureSocket.connect(
      uri.host,
      uri.hasPort ? uri.port : 443,
      context: SecurityContext(withTrustedRoots: false),
      onBadCertificate: (certificate) => constantTimeEquals(certificateSha256(certificate), expectedSha256),
      timeout: const Duration(seconds: 10),
    );
    final certificate = socket.peerCertificate;
    if (certificate == null || !constantTimeEquals(certificateSha256(certificate), expectedSha256)) {
      await socket.close();
      throw const HandshakeException('TLS leaf certificate fingerprint mismatch');
    }
    return socket;
  }

  Future<Map<String, dynamic>> jsonRequest({required String method, required Uri uri, String? bearer, Object? body}) async {
    const timeout = Duration(seconds: 10);
    const maximumResponseBytes = 1024 * 1024;
    if (uri.scheme != 'https') {
      throw const FormatException('HTTPS endpoint required');
    }
    var pinValidated = false;
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    )..connectionTimeout = timeout;
    client.badCertificateCallback = (certificate, _, _) {
      final matches = constantTimeEquals(
        certificateSha256(certificate),
        expectedSha256,
      );
      pinValidated |= matches;
      return matches;
    };
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.contentType = ContentType.json;
      if (bearer != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
      }
      if (body != null) request.add(utf8.encode(jsonEncode(body)));
      final response = await request.close().timeout(timeout);
      final bytes = <int>[];
      await for (final chunk in response.timeout(timeout)) {
        if (bytes.length + chunk.length > maximumResponseBytes) {
          throw const HttpException('HTTPS response is too large');
        }
        bytes.addAll(chunk);
      }
      if (!pinValidated) {
        throw const HandshakeException(
          'TLS leaf certificate fingerprint was not validated',
        );
      }
      final payload = jsonDecode(utf8.decode(bytes));
      if (payload is! Map) {
        throw const FormatException('HTTPS JSON response must be an object');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Remote request failed (${response.statusCode}): '
          '${payload['message'] ?? payload['code'] ?? 'unknown'}',
          uri: uri,
        );
      }
      return Map<String, dynamic>.from(payload);
    } finally {
      client.close(force: true);
    }
  }
}

String certificateSha256(X509Certificate certificate) => sha256.convert(certificate.der).toString();

bool constantTimeEquals(String left, String right) {
  final a = ascii.encode(left);
  final b = ascii.encode(right);
  var difference = a.length ^ b.length;
  final length = a.length < b.length ? a.length : b.length;
  for (var index = 0; index < length; index++) { difference |= a[index] ^ b[index]; }
  return difference == 0;
}
