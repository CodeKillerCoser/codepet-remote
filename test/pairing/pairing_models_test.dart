import 'dart:io';

import 'package:codepet_remote/pairing/pairing_models.dart';
import 'package:codepet_remote/security/pinned_tls.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Fixture copied from CodePet origin/v0@f5f29fc protocol/gateway/v1/fixtures.
  test('parses the Gateway v1 QR fixture with strict fields', () {
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

  test('certificate fingerprint comparison is constant-work and exact', () {
    expect(constantTimeEquals('a' * 64, 'a' * 64), isTrue);
    expect(constantTimeEquals('a' * 64, '${'a' * 63}b'), isFalse);
    expect(constantTimeEquals('a' * 64, 'a' * 63), isFalse);
  });
}
