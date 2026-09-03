import 'dart:io';

import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/pinned_web_socket_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects a non-wss URI before attempting a connection', () async {
    final transport = PinnedWebSocketGatewayTransport(
      gatewayUri: Uri.parse('ws://127.0.0.1:1/remote/v1/gateway'),
      credential: 'opaque',
      certSha256: '0' * 64,
    );
    expect(transport.connectTimeout, const Duration(seconds: 8));
    expect(transport.keepAliveInterval, const Duration(seconds: 20));

    await expectLater(
      transport.connect(),
      throwsA(
        isA<GatewayConnectionException>().having(
          (error) => error.message,
          'message',
          contains('wss'),
        ),
      ),
    );
    await transport.close();
  });

  test('classifies authentication and TLS failures as non-retryable', () {
    expect(
      isRetryableGatewayFailure(const WebSocketException('unauthorized', 401)),
      isFalse,
    );
    expect(
      isRetryableGatewayFailure(const WebSocketException('forbidden', 403)),
      isFalse,
    );
    expect(
      isRetryableGatewayFailure(const HandshakeException('pin mismatch')),
      isFalse,
    );
    expect(
      isRetryableGatewayFailure(const GatewayConnectionException(
        'unavailable',
        retryable: true,
      )),
      isTrue,
    );
  });

  test('retries transient network and server close codes', () {
    expect(
      isRetryableWebSocketCloseCode(WebSocketStatus.goingAway),
      isTrue,
    );
    expect(
      isRetryableWebSocketCloseCode(WebSocketStatus.abnormalClosure),
      isTrue,
    );
    expect(
      isRetryableWebSocketCloseCode(WebSocketStatus.normalClosure),
      isFalse,
    );
    expect(
      isRetryableWebSocketCloseCode(WebSocketStatus.protocolError),
      isFalse,
    );
    expect(
      isRetryableWebSocketCloseCode(WebSocketStatus.policyViolation),
      isFalse,
    );
    expect(
      isRetryableWebSocketCloseCode(WebSocketStatus.internalServerError),
      isTrue,
    );
    expect(isRetryableWebSocketCloseCode(1012), isTrue);
    expect(isRetryableWebSocketCloseCode(1013), isTrue);
    expect(isRetryableWebSocketCloseCode(null), isFalse);
  });
}
