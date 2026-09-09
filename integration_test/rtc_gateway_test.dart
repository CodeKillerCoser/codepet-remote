import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:codepet_remote/gateway/webrtc/signaling.dart';
import 'package:codepet_remote/gateway/webrtc/webrtc_gateway_transport.dart';
import 'package:codepet_remote/security/pinned_tls.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'native Android RTC exchanges Gateway RPC and receives credential revocation',
    (tester) async {
      const uriValue = String.fromEnvironment('RTC_GATEWAY_URI');
      const pin = String.fromEnvironment('RTC_PIN');
      const credential = String.fromEnvironment('RTC_CREDENTIAL');
      const handshakeValue = String.fromEnvironment('RTC_HANDSHAKE');
      const eventRequest = String.fromEnvironment('RTC_EVENT_REQUEST');
      expect(
        uriValue,
        isNotEmpty,
        reason: 'Use the ephemeral Host probe config',
      );
      final uri = Uri.parse(uriValue);
      final transport = WebRtcGatewayTransport(
        signaling: PinnedLanRtcSignaling(
          gatewayUri: uri,
          credential: credential,
          certSha256: pin,
        ),
      );
      final errors = <Object>[];
      final events = <Map<String, dynamic>>[];
      final subscription = transport.events.listen(
        events.add,
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      addTearDown(transport.close);
      await transport.connect();
      final handshake = await transport.request(
        Map<String, Object?>.from(jsonDecode(handshakeValue) as Map),
      );
      expect((handshake as Map)['result'], isNotNull);
      final largeId = 'android-${'界' * 24000}';
      final response = await transport.request({
        'jsonrpc': '2.0',
        'id': largeId,
        'method': 'provider.list',
        'params': {},
      });
      expect((response as Map)['id'], largeId);
      expect(response['result'], isNotNull);
      final ping = await transport.request({
        'jsonrpc': '2.0',
        'id': 'probe-ping',
        'method': 'protocol.ping',
        'params': {'sequence': 1},
      });
      expect(((ping as Map)['result'] as Map)['sequence'], 1);
      final subscribed = await transport.request({
        'jsonrpc': '2.0',
        'id': 'probe-subscribe',
        'method': 'event.subscribe',
        'params': {'afterCursor': (handshake['result'] as Map)['eventCursor']},
      });
      expect((subscribed as Map)['result'], isNotNull);
      final triggered = await transport.request(
        Map<String, Object?>.from(jsonDecode(eventRequest) as Map),
      );
      expect((triggered as Map)['result'], isNotNull);
      for (var i = 0; i < 100 && events.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        events,
        isNotEmpty,
        reason: 'Native RTC must deliver Gateway notifications',
      );
      expect(
        events.every(
          (event) => event['jsonrpc'] == '2.0' && event['method'] is String,
        ),
        isTrue,
      );
      await PinnedTlsConnection(expectedSha256: pin).jsonRequest(
        method: 'DELETE',
        uri: uri.replace(
          scheme: 'https',
          path: '/remote/v1/credentials/current',
        ),
        bearer: credential,
      );
      for (var i = 0; i < 100 && errors.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        errors,
        isNotEmpty,
        reason: 'RTC must close when its credential is revoked',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
