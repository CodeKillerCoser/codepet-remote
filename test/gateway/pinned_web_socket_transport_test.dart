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
}
