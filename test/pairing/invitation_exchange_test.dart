import 'dart:async';
import 'dart:convert';

import 'package:codepet_remote/pairing/invitation_exchange.dart';
import 'package:codepet_remote/pairing/pairing_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an early failed route never wins over a validated success', () async {
    final good = Completer<String>();
    final result = firstValid([
      Future<String>.error(const FormatException('bad pin')),
      good.future,
    ]);
    await Future<void>.delayed(Duration.zero);
    good.complete('accepted');
    expect(await result, 'accepted');
  });

  test('late errors and duplicate successes do not complete twice', () async {
    final late = Completer<String>();
    final result = firstValid([Future.value('one'), late.future]);
    expect(await result, 'one');
    late.completeError(StateError('cancelled'));
    await Future<void>.delayed(Duration.zero);
    expect(await firstValid([Future.value('one'), Future.value('two')]), 'one');
  });

  test('all routes failing reports failure', () async {
    await expectLater(
      firstValid<String>([
        Future.error(StateError('LAN down')),
        Future.error(StateError('VPS down')),
      ]),
      throwsStateError,
    );
  });

  test('encrypted result binds Host, invitation, phone request and cloud authorization', () async {
    final host = await Ed25519().newKeyPairFromSeed(List.filled(32, 7));
    final public = base64Encode((await host.extractPublicKey()).bytes);
    final qr = PairingQrPayload(
      version: 2,
      hostDeviceId: 'host',
      displayName: 'Host',
      httpsBaseUrl: Uri.parse('https://192.0.2.1:1234'),
      certSha256: 'a' * 64,
      pairingId: 'invitation',
      pairingSecret: 'b' * 64,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        ((DateTime.now().millisecondsSinceEpoch ~/ 1000) + 120) * 1000,
        isUtc: true,
      ),
      serviceUrl: Uri.parse('https://signal.example'),
      hostPublicKey: public,
    );
    final result = <String, dynamic>{
      'v': 2,
      'host': 'host',
      'invitationId': 'invitation',
      'requestId': 'request',
      'requestHash': 'hash',
      'expires': qr.expiresAt.millisecondsSinceEpoch ~/ 1000,
      'state': 'accepted',
      'pairing': {
        'device': {
          'deviceId': 'host',
          'identityFingerprint': 'a' * 64,
          'descriptor': {
            'deviceName': 'Host',
            'operatingSystem': 'Windows',
            'systemVersion': '11',
          },
        },
        'gatewayUrl': 'wss://192.0.2.1:1234/remote/v1/gateway',
        'credential': 'bearer',
      },
      'cloud': {
        'host': 'host',
        'hostPublicKey': public,
        'serviceUrl': 'https://signal.example',
        'client': 'credential-id',
        'token': 't' * 44,
      },
    };
    Future<String> seal(
      Map<String, dynamic> value, {
      bool badSignature = false,
    }) async {
      final payload = utf8.encode(jsonEncode(value));
      final signature = await Ed25519().sign(payload, keyPair: host);
      final signed = utf8.encode(
        jsonEncode({
          'payload': base64Encode(payload),
          'signature': base64Encode(
            badSignature ? List.filled(64, 0) : signature.bytes,
          ),
        }),
      );
      final box = await AesGcm.with256bits().encrypt(
        signed,
        secretKey: invitationKey(qr.pairingSecret, 'result'),
        aad: utf8.encode('host:invitation:request'),
      );
      return base64Encode(box.concatenation());
    }

    expect(
      (await verifyInvitationResult(
        qr,
        await seal(result),
        'request',
        'hash',
      ))['state'],
      'accepted',
    );
    for (final change in [
      {'host': 'other'},
      {'invitationId': 'other'},
      {'requestId': 'other'},
      {'requestHash': 'other'},
      {'expires': 0},
      {'state': 'rejected'},
      {
        'cloud': {
          ...result['cloud'] as Map,
          'hostPublicKey': base64Encode(List.filled(32, 0)),
        },
      },
    ]) {
      await expectLater(
        verifyInvitationResult(
          qr,
          await seal({...result, ...change}),
          'request',
          'hash',
        ),
        throwsFormatException,
      );
    }
    await expectLater(
      verifyInvitationResult(
        qr,
        await seal(result, badSignature: true),
        'request',
        'hash',
      ),
      throwsFormatException,
    );
    await expectLater(
      verifyInvitationResult(
        qr,
        await seal(result),
        'different-request',
        'hash',
      ),
      throwsA(isA<SecretBoxAuthenticationError>()),
    );
  });
}
