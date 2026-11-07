import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codepet_remote/gateway/webrtc/cloud_signaling.dart';
import 'package:codepet_remote/gateway/webrtc/path_policy.dart';
import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHeaders implements HttpHeaders {
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  set contentType(ContentType? value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  FakeResponse(this.body);
  final Object body;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode(jsonEncode(body))).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeRequest implements HttpClientRequest {
  FakeRequest(this.server, this.method, this.uri);
  final FakeHttp server;
  @override
  final String method;
  @override
  final Uri uri;
  final bytes = <int>[];
  @override
  final HttpHeaders headers = FakeHeaders();
  @override
  bool followRedirects = false;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async => FakeResponse(
    await server.handle(
      method,
      uri.path,
      bytes.isEmpty ? null : jsonDecode(utf8.decode(bytes)),
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttp implements HttpClient {
  FakeHttp(this.handle);
  final Future<Object> Function(String, String, Object?) handle;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async =>
      FakeRequest(this, method, url);
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'late candidate batches are signed and bound to the submitted offer',
    () async {
      final algorithm = Ed25519();
      final seed = List<int>.filled(32, 7);
      final client = await algorithm.newKeyPairFromSeed(seed);
      final host = await algorithm.newKeyPair();
      Map<String, dynamic>? offer;
      String? offerHash;
      final updates = <Map<String, dynamic>>[];
      final published = Completer<void>();
      final http = FakeHttp((method, path, body) async {
        if (path == '/v1/ice') {
          return {
            'trickleIce': true,
            'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            'iceServers': [],
          };
        }
        if (method == 'DELETE') return {'ok': true};
        if (method == 'POST') {
          final envelope = (body as Map)['envelope'] as Map;
          final bytes = base64Decode(envelope['payload'] as String);
          expect(
            await algorithm.verify(
              bytes,
              signature: Signature(
                base64Decode(envelope['signature'] as String),
                publicKey: await client.extractPublicKey(),
              ),
            ),
            true,
          );
          final value = Map<String, dynamic>.from(
            jsonDecode(utf8.decode(bytes)) as Map,
          );
          if (path == '/v1/offers') {
            offer = value;
            offerHash = hashes.sha256.convert(bytes).toString();
            published.complete();
          } else {
            expect(path, '/v1/ice-updates');
            expect(value['kind'], 'ice-update');
            expect(value['offerHash'], offerHash);
            for (final key in ['host', 'client', 'attempt', 'expires']) {
              expect(value[key], offer![key]);
            }
            expect(value['sequence'], updates.length);
            updates.add(value);
          }
          return {'ok': true};
        }
        if (updates.isEmpty) return {'answer': null};
        final payload = utf8.encode(
          jsonEncode({
            ...offer!,
            'kind': 'answer',
            'offerHash': offerHash,
            'description': {'type': 'answer', 'sdp': 'answer'},
          }),
        );
        return {
          'answer': {
            'payload': base64Encode(payload),
            'signature': base64Encode(
              (await algorithm.sign(payload, keyPair: host)).bytes,
            ),
          },
        };
      });
      await HttpOverrides.runZoned(() async {
        final signaling = CloudRtcSignaling({
          'serviceUrl': 'https://test.invalid',
          'host': 'host',
          'client': 'client',
          'seed': base64Encode(seed),
          'token': 'private',
          'hostPublicKey': base64Encode((await host.extractPublicKey()).bytes),
        }, pathPolicy: RtcPathPolicy.ipv4Direct);
        try {
          await signaling.configuration();
          expect(signaling.trickleEnabled, true);
          final answer = signaling.answer({
            'type': 'offer',
            'sdp': 'empty-offer',
          });
          await published.future;
          signaling.localCandidate({
            'candidate': 'candidate:1 1 udp 1 192.0.2.1 1234 typ host',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          });
          signaling.localCandidate(null);
          expect((await answer)['sdp'], 'answer');
          expect(updates.single['complete'], true);
          expect((updates.single['candidates'] as List), hasLength(1));
          signaling.finishTrickle();
        } finally {
          signaling.close();
        }
      }, createHttpClient: (_) => http);
    },
  );
}
