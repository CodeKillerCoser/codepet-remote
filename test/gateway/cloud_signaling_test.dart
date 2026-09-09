import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/gateway/webrtc/cloud_signaling.dart';

void main() {
  test(
    'signed answers bind the paired peer, attempt, offer and expiry',
    () async {
      final algorithm = Ed25519();
      final key = await algorithm.newKeyPair();
      final state = {
        'host': 'host',
        'client': 'client',
        'hostPublicKey': base64Encode((await key.extractPublicKey()).bytes),
      };
      final body = {
        'v': 1,
        'kind': 'answer',
        'host': 'host',
        'client': 'client',
        'attempt': 'attempt',
        'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60,
        'offerHash': 'digest',
        'description': {'type': 'answer', 'sdp': 'test'},
      };
      Future<Map<String, dynamic>> sign(Map<String, dynamic> value) async {
        final bytes = utf8.encode(jsonEncode(value));
        return {
          'payload': base64Encode(bytes),
          'signature': base64Encode(
            (await algorithm.sign(bytes, keyPair: key)).bytes,
          ),
        };
      }

      final envelope = await sign(body);
      expect(
        (await CloudRtcSignaling.verifyAnswer(
          envelope,
          state,
          'attempt',
          'digest',
        ))['sdp'],
        'test',
      );
      for (final change in [
        {'host': 'other'},
        {'client': 'other'},
        {'attempt': 'stale'},
        {'offerHash': 'other'},
        {'expires': 0},
        {'kind': 'offer'},
      ]) {
        final modified = await sign({...body, ...change});
        await expectLater(
          CloudRtcSignaling.verifyAnswer(modified, state, 'attempt', 'digest'),
          throwsFormatException,
        );
      }
      await expectLater(
        CloudRtcSignaling.verifyAnswer(
          {...envelope, 'signature': base64Encode(List.filled(64, 0))},
          state,
          'attempt',
          'digest',
        ),
        throwsFormatException,
      );
    },
  );
}
