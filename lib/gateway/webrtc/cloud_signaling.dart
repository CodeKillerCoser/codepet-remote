import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../application/errors/application_failures.dart';
import '../../security/pinned_tls.dart';
import 'signaling.dart';
import 'rtc_diagnostics.dart';

/// A new key is pinned only over the existing LAN TLS/bearer boundary.
class CloudPairing {
  CloudPairing(this.host, this.credential, this.pin);
  final String host, credential, pin;
  static const storage = FlutterSecureStorage(aOptions: AndroidOptions());
  String get key =>
      'rtc_cloud_${hashes.sha256.convert(utf8.encode('$host:$credential'))}';

  Future<Map<String, dynamic>?> load() async {
    final value = await storage.read(key: key);
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> bootstrap(Uri gateway) async {
    var state = await load();
    if (state == null) {
      final pair = await Ed25519().newKeyPair();
      state = {'seed': base64Encode(await pair.extractPrivateKeyBytes())};
      // Persist before registering: a lost HTTP response must reuse the same key.
      await storage.write(key: key, value: jsonEncode(state));
    }
    final pair = await Ed25519().newKeyPairFromSeed(
      base64Decode(state['seed'] as String),
    );
    final response = await PinnedTlsConnection(expectedSha256: pin).jsonRequest(
      method: 'POST',
      uri: gateway.replace(
        scheme: 'https',
        path: '/remote/v1/channel-bootstrap',
        query: '',
        fragment: '',
      ),
      bearer: credential,
      body: {'publicKey': base64Encode((await pair.extractPublicKey()).bytes)},
    );
    final url = Uri.parse(response['serviceUrl'] as String);
    if (response['host'] != host ||
        url.scheme != 'https' ||
        url.userInfo.isNotEmpty ||
        url.hasQuery ||
        url.hasFragment ||
        base64Decode(response['hostPublicKey'] as String).length != 32 ||
        (response['token'] as String).length < 32) {
      throw const FormatException('Invalid cloud bootstrap');
    }
    if (state['hostPublicKey'] != null &&
        state['hostPublicKey'] != response['hostPublicKey']) {
      throw const FormatException('Cloud Host key changed; pair again on LAN');
    }
    await storage.write(
      key: key,
      value: jsonEncode({...response, 'seed': state['seed']}),
    );
  }
}

class CloudRtcSignaling implements RtcIceSignaling {
  CloudRtcSignaling(this.state, {this.forceRelay = false});
  final Map<String, dynamic> state;
  final bool forceRelay;
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  bool _closed = false;
  int? iceExpires;
  final _diagnostics = RtcDiagnostics();

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Object? body,
  ]) async {
    if (_closed) {
      throw const GatewayConnectionException('Cloud signaling closed');
    }
    final uri = Uri.parse('${state['serviceUrl']}$path');
    if (uri.scheme != 'https') {
      throw const FormatException('Cloud requires HTTPS');
    }
    final started = Stopwatch()..start();
    final request = await _http
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 12));
    request.followRedirects = false;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${state['token']}',
    );
    request.headers.contentType = ContentType.json;
    if (body != null) request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close().timeout(const Duration(seconds: 12));
    _diagnostics.emit('signal.http', {
      'method': method,
      'path': uri.path,
      'status': response.statusCode,
      'durationMs': started.elapsedMilliseconds,
    });
    if (response.statusCode != 200) {
      throw GatewayConnectionException(
        'Cloud signaling status ${response.statusCode}',
        retryable: response.statusCode != 401 && response.statusCode != 403,
      );
    }
    final bytes = <int>[];
    await for (final part in response.timeout(const Duration(seconds: 12))) {
      if (bytes.length + part.length > 100000) {
        throw const FormatException('Cloud response too large');
      }
      bytes.addAll(part);
    }
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
  }

  @override
  Future<Map<String, dynamic>> configuration() async {
    final value = await _request('GET', '/v1/ice');
    iceExpires = value['expires'] as int;
    return {
      'iceServers': value['iceServers'],
      if (forceRelay) 'iceTransportPolicy': 'relay',
    };
  }

  @override
  Future<Map<String, dynamic>> answer(Map<String, dynamic> offer) async {
    final algorithm = Ed25519();
    final key = await algorithm.newKeyPairFromSeed(
      base64Decode(state['seed'] as String),
    );
    final nonce = await algorithm.newKeyPair();
    final attempt = hashes.sha256
        .convert(await nonce.extractPrivateKeyBytes())
        .toString();
    _diagnostics.offerId = rtcOfferId(offer['sdp'] as String);
    _diagnostics.emit('signal.attempt', {'attempt': attempt});
    final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60;
    final payload = utf8.encode(
      jsonEncode({
        'v': 1,
        'kind': 'offer',
        'host': state['host'],
        'client': state['client'],
        'attempt': attempt,
        'expires': expires,
        'description': offer,
      }),
    );
    final signature = await algorithm.sign(payload, keyPair: key);
    await _request('POST', '/v1/offers', {
      'attempt': attempt,
      'envelope': {
        'payload': base64Encode(payload),
        'signature': base64Encode(signature.bytes),
      },
    });
    while (!_closed &&
        DateTime.now().millisecondsSinceEpoch ~/ 1000 < expires) {
      final result = await _request('GET', '/v1/answer?attempt=$attempt');
      if (result['answer'] != null) {
        return verifyAnswer(
          Map<String, dynamic>.from(result['answer'] as Map),
          state,
          attempt,
          hashes.sha256.convert(payload).toString(),
        );
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    throw const GatewayConnectionException(
      'Cloud answer timed out',
      retryable: true,
    );
  }

  static Future<Map<String, dynamic>> verifyAnswer(
    Map<String, dynamic> envelope,
    Map<String, dynamic> state,
    String attempt,
    String offerHash,
  ) async {
    final payload = base64Decode(envelope['payload'] as String);
    if (payload.length > 65536) throw const FormatException('Answer too large');
    final valid = await Ed25519().verify(
      payload,
      signature: Signature(
        base64Decode(envelope['signature'] as String),
        publicKey: SimplePublicKey(
          base64Decode(state['hostPublicKey'] as String),
          type: KeyPairType.ed25519,
        ),
      ),
    );
    if (!valid) throw const FormatException('Cloud peer signature rejected');
    final value = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(payload)) as Map,
    );
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (value['v'] != 1 ||
        value['kind'] != 'answer' ||
        value['host'] != state['host'] ||
        value['client'] != state['client'] ||
        value['attempt'] != attempt ||
        value['offerHash'] != offerHash ||
        value['expires'] is! int ||
        (value['expires'] as int) <= now ||
        (value['expires'] as int) > now + 90) {
      throw const FormatException('Cloud answer binding rejected');
    }
    return Map<String, dynamic>.from(value['description'] as Map);
  }

  @override
  void close() {
    _closed = true;
    _http.close(force: true);
  }
}
