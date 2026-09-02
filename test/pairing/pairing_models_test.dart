import 'dart:io';
import 'dart:convert';

import 'package:codepet_remote/pairing/pairing_models.dart';
import 'package:codepet_remote/security/pinned_tls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Fixture copied from CodePet@7c06e05 protocol/gateway/v1/fixtures.
  test('parses the Gateway QR fixture with generated strict fields', () {
    final source = File('test/fixtures/gateway_v1/pairing-qr-payload.json').readAsStringSync();
    final qr = PairingQrPayload.parse(source, now: DateTime.utc(2026, 1, 1));
    expect(qr.hostDeviceId, 'device-macbook-1');
    expect(qr.exchangeUrl.path, '/remote/v1/pairings/pairing-0123456789abcdef/exchange');
    expect(qr.certSha256, hasLength(64));
  });

  test('rejects expired, extra-field, insecure and malformed fingerprints', () {
    String payload(String extras, String url, String fingerprint, int expiresAt) => '{"version":1,"hostDeviceId":"d","displayName":"h","httpsBaseUrl":"$url","certSha256":"$fingerprint","pairingId":"p","pairingSecret":"${'a' * 64}","expiresAt":$expiresAt$extras}';
    expect(() => PairingQrPayload.parse(payload('', 'https://host:1', 'b' * 64, 1)), throwsFormatException);
    expect(() => PairingQrPayload.parse(payload(',"extra":true', 'https://host:1', 'b' * 64, 9999999999999)), throwsFormatException);
    expect(() => PairingQrPayload.parse(payload('', 'http://host:1', 'b' * 64, 9999999999999)), throwsFormatException);
    expect(() => PairingQrPayload.parse(payload('', 'https://host:1', 'B' * 64, 9999999999999)), throwsFormatException);
  });

  test('does not confuse the Gateway version with the LAN QR version', () {
    final source = File('test/fixtures/gateway_v1/pairing-qr-payload.json')
        .readAsStringSync()
        .replaceFirst('"version": 1', '"version": 2');

    expect(
      () => PairingQrPayload.parse(source, now: DateTime.utc(2026, 1, 1)),
      throwsFormatException,
    );
  });

  test('certificate fingerprint comparison is constant-work and exact', () {
    expect(constantTimeEquals('a' * 64, 'a' * 64), isTrue);
    expect(constantTimeEquals('a' * 64, '${'a' * 63}b'), isFalse);
    expect(constantTimeEquals('a' * 64, 'a' * 63), isFalse);
  });

  test('decodes the Host descriptor from the pairing exchange fixture', () {
    final json = jsonDecode(
      File('test/fixtures/gateway_v1/pairing-exchange-response.json')
          .readAsStringSync(),
    ) as Map;
    final response = PairingExchangeResponse.fromJson(
      Map<String, dynamic>.from(json),
    );

    expect(response.device.descriptor.deviceName, 'MacBook');
    expect(response.device.descriptor.operatingSystem, 'macOS');
    expect(response.device.descriptor.systemVersion, '15.6');
  });

  test('rejects the obsolete Host identity shape without descriptor', () {
    expect(
      () => PairingExchangeResponse.fromJson({
        'device': {
          'deviceId': 'device-old',
          'displayName': 'Old Host',
          'identityFingerprint': 'a' * 64,
        },
        'gatewayUrl': 'wss://host:1/remote/v1/gateway',
        'credential': 'opaque',
      }),
      throwsFormatException,
    );
  });
}
