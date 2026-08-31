import 'dart:io';

import 'package:codepet_remote/gateway/pinned_web_socket_transport.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rejects a non-wss URI before attempting a connection', () async {
    final transport = PinnedWebSocketGatewayTransport(
      gatewayUri: Uri.parse('ws://127.0.0.1:1/remote/v1/gateway'),
      credential: 'opaque',
      certSha256: '0' * 64,
    );

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
      isRetryableGatewayFailure(const WebSocketException('unavailable', 503)),
      isTrue,
    );
  });

  test('retries only an abnormal network close code', () {
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
      isFalse,
    );
    expect(isRetryableWebSocketCloseCode(null), isFalse);
  });
}
