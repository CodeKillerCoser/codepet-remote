import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/pinned_web_socket_transport.dart';

// Supply an ephemeral, self-signed test certificate via --dart-define-from-file.
// This server runs entirely inside the emulator; it never acquires a real thread.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native LAN preserves late acquire/resume acknowledgements', (
    tester,
  ) async {
    final certificate = utf8.decode(
      base64Decode(const String.fromEnvironment('TEST_TLS_CERT_B64')),
    );
    final privateKey = utf8.decode(
      base64Decode(const String.fromEnvironment('TEST_TLS_KEY_B64')),
    );
    expect(certificate, isNotEmpty);
    expect(privateKey, isNotEmpty);
    final context = SecurityContext()
      ..useCertificateChainBytes(utf8.encode(certificate))
      ..usePrivateKeyBytes(utf8.encode(privateKey));
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    final sockets = <WebSocket>[];
    final timers = <Timer>[];
    final served = <String>[];
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      sockets.add(socket);
      socket.listen((frame) {
        final request = jsonDecode(frame as String) as Map;
        final method = request['method'] as String;
        served.add(method);
        void reply() => socket.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': {'interactionAcquired': true},
          }),
        );
        if (method == 'conversation.get') {
          return; // Still has its ordinary deadline.
        }
        if (method == 'conversation.acquireInteraction' ||
            method == 'conversation.resume') {
          timers.add(Timer(const Duration(seconds: 31), reply));
        } else {
          reply();
        }
      });
    });
    final der = base64Decode(
      certificate.split('\n').where((line) => !line.startsWith('-----')).join(),
    );
    final transport = PinnedWebSocketGatewayTransport(
      gatewayUri: Uri.parse('wss://127.0.0.1:${server.port}/gateway'),
      credential: 'isolated-test',
      certSha256: sha256.convert(der).toString(),
    );
    addTearDown(() async {
      for (final timer in timers) {
        timer.cancel();
      }
      await transport.close();
      for (final socket in sockets) {
        await socket.close();
      }
      await server.close(force: true);
    });
    await transport.connect();
    Object? historyError;
    final history = transport
        .request({'id': 'history', 'method': 'conversation.get'})
        .catchError((Object error) {
          historyError = error;
          return null;
        });
    final responses = await Future.wait([
      transport.request({
        'id': 'acquire',
        'method': 'conversation.acquireInteraction',
      }),
      transport.request({'id': 'resume', 'method': 'conversation.resume'}),
    ]);
    await history;
    expect(historyError, isA<GatewayConnectionException>());
    for (final response in responses) {
      expect((response as Map)['result']['interactionAcquired'], isTrue);
    }
    expect(
      served.where((method) => method == 'conversation.acquireInteraction'),
      hasLength(1),
    );
    expect(
      served.where((method) => method == 'conversation.resume'),
      hasLength(1),
    );
    expect(
      await transport.request({'id': 'next', 'method': 'provider.list'}),
      isA<Map>(),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));
}
