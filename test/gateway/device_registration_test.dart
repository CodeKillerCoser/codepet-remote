import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/gateway/webrtc/device_registration.dart';

void main() {
  test('registration signs identity and persists before sending; restart and response loss reuse the same grant', () async {
    final storage = <String, String>{};
    final payloads = <Map<String, dynamic>>[];
    final publicKeys = <String>[];
    var fail = true;
    Future<Map<String, dynamic>> post(
      Uri uri,
      Map<String, dynamic> envelope,
    ) async {
      expect(uri.toString(), startsWith('https://'));
      expect(storage, hasLength(uri.host == 'second.example.com' ? 3 : 2));
      final payload = base64Decode(envelope['payload']);
      final body = Map<String, dynamic>.from(jsonDecode(utf8.decode(payload)));
      expect(
        await Ed25519().verify(
          payload,
          signature: Signature(
            base64Decode(envelope['signature']),
            publicKey: SimplePublicKey(
              base64Decode(envelope['publicKey']),
              type: KeyPairType.ed25519,
            ),
          ),
        ),
        isTrue,
      );
      expect(body['role'], 'remote');
      expect(body['deviceId'], 'remote-test');
      expect(body['tokenHash'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(envelope.containsKey('token'), isFalse);
      payloads.add(body);
      publicKeys.add(envelope['publicKey']);
      if (fail) throw StateError('response lost');
      return {
        'protocol': 'codepet-device-registration-v1',
        'deviceId': 'remote-test',
        'role': 'remote',
        'status': 'registered',
      };
    }

    SignalingDeviceRegistration create() => SignalingDeviceRegistration(
      deviceId: () async => 'remote-test',
      read: (key) async => storage[key],
      write: (key, value) async {
        storage[key] = value;
      },
      post: post,
    );
    await expectLater(
      create().register('172.96.254.12'),
      throwsA(isA<SignalingRegistrationException>()),
    );
    fail = false;
    final restarted = create();
    await restarted.register('172.96.254.12');
    expect(payloads[0]['tokenHash'], payloads[1]['tokenHash']);
    expect(publicKeys.toSet(), hasLength(1));
    await restarted.register('172.96.254.12');
    expect(payloads, hasLength(2));
    await restarted.register('second.example.com');
    expect(payloads.last['tokenHash'], isNot(payloads.first['tokenHash']));
    expect(publicKeys.toSet(), hasLength(1));
  });

  test('mismatched server claims never report successful enrollment', () async {
    final storage = <String, String>{};
    var calls = 0;
    final registration = SignalingDeviceRegistration(
      deviceId: () async => 'remote-test',
      read: (key) async => storage[key],
      write: (key, value) async {
        storage[key] = value;
      },
      post: (uri, body) async {
        calls++;
        return {
          'protocol': 'codepet-device-registration-v1',
          'deviceId': 'other',
          'role': 'host',
          'status': 'registered',
        };
      },
    );
    for (var n = 0; n < 2; n++) {
      await expectLater(
        registration.register('signal.example.com'),
        throwsA(isA<SignalingRegistrationException>()),
      );
    }
    expect(calls, 2);
  });
}
