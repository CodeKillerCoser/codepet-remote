import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../application/errors/application_failures.dart';
import '../../core/domain/signaling_service.dart';
import '../../security/pinned_tls.dart';
import 'signaling.dart';
import 'rtc_diagnostics.dart';
import 'path_policy.dart';
import 'ice_configuration_cache.dart';

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

  /// The caller has verified the QR-pinned Host signature and invitation binding.
  Future<void> storeInvitation(Map<String, dynamic> state, List<int> seed) =>
      storage.write(
        key: key,
        value: jsonEncode({...state, 'seed': base64Encode(seed)}),
      );

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

/// Never forward an existing service's bearer to a different configured origin.
void validateSignalingServiceBinding(
  Map<String, dynamic> state,
  String? selected,
) {
  if (selected == null) return;
  final expected = normalizeSignalingService(selected);
  final actual = normalizeSignalingService(
    state['serviceUrl'] as String? ?? '',
  );
  if (expected != null && expected != actual) {
    throw const GatewayConnectionException('信令服务已更改，请让电脑使用相同服务并重新配对。');
  }
}

class CloudRtcSignaling implements RtcTrickleSignaling {
  CloudRtcSignaling(
    this.state, {
    this.forceRelay = false,
    this.pathPolicy = RtcPathPolicy.auto,
    IceConfigurationCache? iceCache,
    RtcDiagnostics? diagnostics,
  }) : _iceCache = iceCache ?? IceConfigurationCache(),
       _diagnostics =
           diagnostics ?? RtcDiagnostics(pathPolicy: pathPolicy.wireName);
  final Map<String, dynamic> state;
  final bool forceRelay;
  final RtcPathPolicy pathPolicy;
  final IceConfigurationCache _iceCache;
  String? _attempt;
  int _answerPolls = 0;
  final _answerWait = Stopwatch();
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);
  bool _closed = false;
  int? iceExpires;
  final RtcDiagnostics _diagnostics;
  @override
  bool trickleEnabled = false;
  final _localCandidates = <Map<String, dynamic>>[];
  final _candidateKeys = <String>{};
  bool _localComplete = false;
  bool _trickleFinished = false;
  Object? _trickleFailure;

  @override
  void localCandidate(Map<String, dynamic>? candidate) {
    if (!trickleEnabled || _trickleFinished) return;
    if (candidate == null) {
      _localComplete = true;
      return;
    }
    final key = candidate['candidate'] as String;
    if (!_candidateKeys.add(key)) return;
    if (_candidateKeys.length > 128 || key.length > 1024) {
      _trickleFailure = const FormatException('Too many ICE candidates');
      return;
    }
    _localCandidates.add(candidate);
  }

  @override
  void checkTrickleFailure() {
    final failure = _trickleFailure;
    if (failure != null) throw failure;
  }

  @override
  void finishTrickle() {
    _trickleFinished = true;
  }

  Future<void> _publishCandidates(
    SimpleKeyPair key,
    String attempt,
    int expires,
    String offerHash,
  ) async {
    var sequence = 0;
    try {
      while (!_closed &&
          !_trickleFinished &&
          DateTime.now().millisecondsSinceEpoch ~/ 1000 < expires) {
        if (_localCandidates.isEmpty && !_localComplete) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          continue;
        }
        final batch = _localCandidates.take(8).toList();
        _localCandidates.removeRange(0, batch.length);
        final complete = _localComplete && _localCandidates.isEmpty;
        final payload = utf8.encode(
          jsonEncode({
            'v': 1,
            'kind': 'ice-update',
            'host': state['host'],
            'client': state['client'],
            'attempt': attempt,
            'expires': expires,
            'offerHash': offerHash,
            'sequence': sequence,
            'candidates': batch,
            'complete': complete,
          }),
        );
        final signature = await Ed25519().sign(payload, keyPair: key);
        final body = {
          'attempt': attempt,
          'sequence': sequence,
          'envelope': {
            'payload': base64Encode(payload),
            'signature': base64Encode(signature.bytes),
          },
        };
        await _request('POST', '/v1/ice-updates', body);
        _diagnostics.emit('ice.update.sent', {
          'sequence': sequence,
          'count': batch.length,
          'complete': complete,
        });
        sequence++;
        if (complete) return;
      }
    } catch (error) {
      if (!_closed && !_trickleFinished) {
        _trickleFailure = error;
        _diagnostics.emit('ice.update.failed', rtcFailure(error));
      }
    }
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, [
    Object? body,
  ]) async {
    if (_closed) {
      throw const GatewayConnectionException('Cloud signaling closed');
    }
    return _requestWith(_http, method, path, body);
  }

  Future<Map<String, dynamic>> _requestWith(
    HttpClient http,
    String method,
    String path, [
    Object? body,
  ]) async {
    final uri = Uri.parse('${state['serviceUrl']}$path');
    if (uri.scheme != 'https') {
      throw const FormatException('Cloud requires HTTPS');
    }
    final started = Stopwatch()..start();
    final request = await http
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
    // Successful answer polls are summarized below. Failures remain immediate.
    if (method != 'GET' ||
        uri.path != '/v1/answer' ||
        response.statusCode != 200) {
      _diagnostics.emit('signal.http', {
        'method': method,
        'path': uri.path,
        'status': response.statusCode,
        'durationMs': started.elapsedMilliseconds,
      });
    }
    if (response.statusCode != 200) {
      if (response.statusCode == 401 || response.statusCode == 403) {
        _iceCache.invalidate(state);
      }
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
    if (_closed) {
      throw const GatewayConnectionException('Cloud signaling closed');
    }
    if (pathPolicy == RtcPathPolicy.ipv6Direct) {
      return pathPolicy.configuration([]);
    }
    final value = await _iceCache.load(state, () async {
      // The shared request owns its HTTP client. Closing a losing candidate
      // cannot abort the other candidate's configuration fetch.
      final http = HttpClient()
        ..connectionTimeout = const Duration(seconds: 10);
      try {
        return await _requestWith(
          http,
          'GET',
          '/v1/ice',
        ).timeout(const Duration(seconds: 15));
      } finally {
        http.close(force: true);
      }
    });
    if (_closed) {
      throw const GatewayConnectionException('Cloud signaling closed');
    }
    trickleEnabled = value['trickleIce'] == true;
    iceExpires = value['expires'] as int;
    return {
      ...pathPolicy.configuration(value['iceServers'] as List),
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
        if (trickleEnabled) 'trickleIce': true,
        if (pathPolicy != RtcPathPolicy.auto) 'pathPolicy': pathPolicy.wireName,
        'description': offer,
      }),
    );
    final signature = await algorithm.sign(payload, keyPair: key);
    _attempt = attempt;
    await _request('POST', '/v1/offers', {
      'attempt': attempt,
      'envelope': {
        'payload': base64Encode(payload),
        'signature': base64Encode(signature.bytes),
      },
    });
    if (trickleEnabled) {
      unawaited(
        _publishCandidates(
          key,
          attempt,
          expires,
          hashes.sha256.convert(payload).toString(),
        ),
      );
    }
    _answerWait.start();
    while (!_closed &&
        DateTime.now().millisecondsSinceEpoch ~/ 1000 < expires) {
      checkTrickleFailure();
      final result = await _request('GET', '/v1/answer?attempt=$attempt');
      _answerPolls++;
      if (result['answer'] != null) {
        _answerWait.stop();
        return verifyAnswer(
          Map<String, dynamic>.from(result['answer'] as Map),
          state,
          attempt,
          hashes.sha256.convert(payload).toString(),
          expectedPolicy: pathPolicy,
        ).then((answer) {
          _diagnostics.emit('signal.answer.verified', {
            'attempt': attempt,
            'polls': _answerPolls,
            'waitMs': _answerWait.elapsedMilliseconds,
          });
          return answer;
        });
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
    String offerHash, {
    RtcPathPolicy expectedPolicy = RtcPathPolicy.auto,
  }) async {
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
        (expectedPolicy != RtcPathPolicy.auto &&
            value['pathPolicy'] != expectedPolicy.wireName) ||
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
    if (_closed) return;
    finishTrickle();
    // Begin cancellation before closing the HTTP client; bounded and best effort.
    final attempt = _attempt;
    if (attempt != null) {
      unawaited(
        _request('DELETE', '/v1/offers?attempt=$attempt')
            .timeout(const Duration(seconds: 2))
            .then<void>((_) {}, onError: (Object _) {})
            .whenComplete(() => _http.close(force: true)),
      );
    } else {
      _http.close(force: true);
    }
    _closed = true;
    _answerWait.stop();
    _diagnostics.emit('signal.close', {
      'attempt': attempt,
      'cancelRequested': attempt != null,
      'answerPolls': _answerPolls,
      'answerWaitMs': _answerWait.elapsedMilliseconds,
    });
  }
}
