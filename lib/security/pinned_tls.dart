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
    final socket = await connect(uri);
    final encoded = body == null ? <int>[] : utf8.encode(jsonEncode(body));
    final path = uri.hasQuery ? '${uri.path}?${uri.query}' : (uri.path.isEmpty ? '/' : uri.path);
    socket.add(utf8.encode('$method $path HTTP/1.1\r\nHost: ${uri.host}:${uri.hasPort ? uri.port : 443}\r\nContent-Type: application/json\r\nContent-Length: ${encoded.length}\r\n${bearer == null ? '' : 'Authorization: Bearer $bearer\r\n'}Connection: close\r\n\r\n'));
    socket.add(encoded);
    await socket.flush();
    final bytes = await socket.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
    final marker = _indexOf(bytes, const [13, 10, 13, 10]);
    if (marker < 0) throw const HttpException('Invalid HTTPS response');
    final headers = ascii.decode(bytes.sublist(0, marker));
    final status = int.tryParse(headers.split('\r\n').first.split(' ')[1]);
    final payload = jsonDecode(utf8.decode(bytes.sublist(marker + 4)));
    if (payload is! Map) throw const FormatException('HTTPS JSON response must be an object');
    if (status == null || status < 200 || status >= 300) throw HttpException('Remote request failed ($status): ${payload['message'] ?? payload['code'] ?? 'unknown'}');
    return Map<String, dynamic>.from(payload);
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

int _indexOf(List<int> source, List<int> pattern) {
  for (var index = 0; index <= source.length - pattern.length; index++) {
    var matches = true;
    for (var offset = 0; offset < pattern.length; offset++) { if (source[index + offset] != pattern[offset]) { matches = false; break; } }
    if (matches) return index;
  }
  return -1;
}
