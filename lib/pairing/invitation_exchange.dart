import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

import '../gateway/webrtc/cloud_signaling.dart';
import '../security/pinned_tls.dart';
import 'pairing_models.dart';
import 'pairing_confirmation.dart';

/// Returns the first fully validated success. Errors never win the race.
Future<T> firstValid<T>(List<Future<T>> routes) {
  final result = Completer<T>();
  var remaining = routes.length;
  if (remaining == 0) return Future.error(StateError('No pairing routes'));
  for (final route in routes) {
    route.then(
      (value) {
        if (!result.isCompleted) result.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (--remaining == 0 && !result.isCompleted) {
          result.completeError(error, stack);
        }
      },
    );
  }
  return result.future;
}

String invitationHash(List<int> bytes) =>
    hashes.sha256.convert(bytes).toString();

SecretKey invitationKey(String secret, String direction) => SecretKey(
  hashes.sha256
      .convert(utf8.encode('codepet-invite-v2:$direction:$secret'))
      .bytes,
);

class InvitationExchange {
  InvitationExchange(this.qr, {this.onConfirmationCode});
  final void Function(String)? onConfirmationCode;
  final PairingQrPayload qr;
  bool _closed = false;
  final List<HttpClient> _clients = [];

  Future<Map<String, dynamic>> exchange(
    String clientId,
    Map<String, dynamic> device,
  ) async {
    final storageKey =
        'rtc_invitation_pending:${invitationHash(utf8.encode(qr.hostDeviceId))}';
    final invitationIdentity = invitationHash(
      utf8.encode('${qr.pairingId}:${qr.hostPublicKey}:${qr.pairingSecret}'),
    );
    final saved = await CloudPairing.storage.read(key: storageKey);
    Map<String, dynamic>? attempt = saved == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(saved) as Map);
    if (attempt == null || attempt['invitation'] != invitationIdentity) {
      final random = Random.secure();
      final seed = List<int>.generate(32, (_) => random.nextInt(256));
      final pair = await Ed25519().newKeyPairFromSeed(seed);
      final requestId = invitationHash(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      final payload = utf8.encode(
        jsonEncode({
          'v': 2,
          'host': qr.hostDeviceId,
          'invitationId': qr.pairingId,
          'requestId': requestId,
          'expires': qr.expiresAt.millisecondsSinceEpoch ~/ 1000,
          'clientId': clientId,
          'publicKey': base64Encode((await pair.extractPublicKey()).bytes),
          'device': device,
        }),
      );
      final signed = utf8.encode(
        jsonEncode({
          'payload': base64Encode(payload),
          'signature': base64Encode(
            (await Ed25519().sign(payload, keyPair: pair)).bytes,
          ),
        }),
      );
      final aad = utf8.encode('${qr.hostDeviceId}:${qr.pairingId}:$requestId');
      final box = await AesGcm.with256bits().encrypt(
        signed,
        secretKey: invitationKey(qr.pairingSecret, 'request'),
        aad: aad,
      );
      attempt = {
        'invitation': invitationIdentity,
        'seed': base64Encode(seed),
        'requestHash': invitationHash(payload),
        'body': {
          'requestId': requestId,
          'sealed': base64Encode(box.concatenation()),
        },
      };
      // Save before either route sends: a rescan reuses the exact request after response loss.
      await CloudPairing.storage.write(
        key: storageKey,
        value: jsonEncode(attempt),
      );
    }
    final seed = base64Decode(attempt['seed'] as String);
    final body = Map<String, dynamic>.from(attempt['body'] as Map);
    final requestId = body['requestId'] as String;
    final requestHash = attempt['requestHash'] as String;
    onConfirmationCode?.call(
      derivePairingConfirmationCode(
        requestId: requestId,
        clientNonce: requestId,
        certificateFingerprint: qr.certSha256,
      ),
    );
    final deadline = DateTime.now().add(
      const Duration(minutes: 2, seconds: 10),
    );
    Future<Map<String, dynamic>> route(bool lan) async {
      final client = HttpClient(
        context: lan ? SecurityContext(withTrustedRoots: false) : null,
      )..connectionTimeout = const Duration(seconds: 8);
      _clients.add(client);
      if (lan) {
        client.badCertificateCallback = (certificate, _, _) =>
            constantTimeEquals(certificateSha256(certificate), qr.certSha256);
      }
      final uri = lan
          ? qr.httpsBaseUrl.replace(
              path:
                  '/remote/v2/pairings/${Uri.encodeComponent(qr.pairingId)}/exchange',
            )
          : Uri.parse(
              '${qr.serviceUrl.toString().replaceFirst(RegExp(r'/$'), '')}/v1/invitation-exchange',
            );
      try {
        while (!_closed &&
            DateTime.now().isBefore(deadline) &&
            DateTime.now().isBefore(qr.expiresAt)) {
          final request = await client
              .postUrl(uri)
              .timeout(const Duration(seconds: 10));
          request.followRedirects = false;
          request.headers.contentType = ContentType.json;
          if (!lan) {
            request.headers.set(
              HttpHeaders.authorizationHeader,
              'Bearer ${invitationHash(utf8.encode('codepet-invite-v2:mailbox:${qr.pairingSecret}'))}',
            );
          }
          request.add(utf8.encode(jsonEncode(body)));
          final response = await request.close().timeout(
            const Duration(seconds: 10),
          );
          final bytes = <int>[];
          await for (final chunk in response.timeout(
            const Duration(seconds: 10),
          )) {
            if (bytes.length + chunk.length > 24000) {
              throw const FormatException('Pairing response too large');
            }
            bytes.addAll(chunk);
          }
          if (lan &&
              (response.certificate == null ||
                  !constantTimeEquals(
                    certificateSha256(response.certificate!),
                    qr.certSha256,
                  ))) {
            throw const FormatException('Pairing TLS identity mismatch');
          }
          // Host may still be publishing a fresh invitation to rendezvous.
          if (!lan &&
              (response.statusCode == 401 || response.statusCode == 503)) {
            await Future<void>.delayed(const Duration(seconds: 2));
            continue;
          }
          if (response.statusCode != 200) {
            throw HttpException('Pairing route status ${response.statusCode}');
          }
          final value = jsonDecode(utf8.decode(bytes)) as Map;
          if (value['result'] != null) {
            return await verifyInvitationResult(
              qr,
              value['result'] as String,
              requestId,
              requestHash,
            );
          }
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        throw const HttpException('配对等待超时，请在 Host 上确认后重新扫码。');
      } finally {
        client.close(force: true);
      }
    }

    try {
      final result = await firstValid([route(true), route(false)]);
      final pairing = Map<String, dynamic>.from(result['pairing'] as Map);
      // Persist cloud authorization before exposing the single result to the use case.
      await CloudPairing(
        qr.hostDeviceId,
        pairing['credential'] as String,
        qr.certSha256,
      ).storeInvitation(
        Map<String, dynamic>.from(result['cloud'] as Map),
        seed,
      );
      return pairing;
    } finally {
      _closed = true;
      for (final client in _clients) {
        client.close(force: true);
      }
    }
  }
}

Future<Map<String, dynamic>> verifyInvitationResult(
  PairingQrPayload qr,
  String sealed,
  String requestId,
  String requestHash,
) async {
  if (sealed.length > 16000) {
    throw const FormatException('Pairing result too large');
  }
  final bytes = base64Decode(sealed);
  final signed = await AesGcm.with256bits().decrypt(
    SecretBox.fromConcatenation(bytes, nonceLength: 12, macLength: 16),
    secretKey: invitationKey(qr.pairingSecret, 'result'),
    aad: utf8.encode('${qr.hostDeviceId}:${qr.pairingId}:$requestId'),
  );
  final envelope = jsonDecode(utf8.decode(signed)) as Map;
  final payload = base64Decode(envelope['payload'] as String);
  final valid = await Ed25519().verify(
    payload,
    signature: Signature(
      base64Decode(envelope['signature'] as String),
      publicKey: SimplePublicKey(
        base64Decode(qr.hostPublicKey!),
        type: KeyPairType.ed25519,
      ),
    ),
  );
  if (!valid) throw const FormatException('Pairing Host signature rejected');
  final value = Map<String, dynamic>.from(
    jsonDecode(utf8.decode(payload)) as Map,
  );
  if (value['v'] != 2 ||
      value['host'] != qr.hostDeviceId ||
      value['invitationId'] != qr.pairingId ||
      value['requestId'] != requestId ||
      value['requestHash'] != requestHash ||
      value['expires'] != qr.expiresAt.millisecondsSinceEpoch ~/ 1000 ||
      !qr.expiresAt.isAfter(DateTime.now())) {
    throw const FormatException('Pairing result binding rejected');
  }
  if (value['state'] != 'accepted') {
    throw const FormatException('Host 已拒绝配对或邀请已过期。');
  }
  final pairing = PairingExchangeResponse.fromJson(
    Map<String, dynamic>.from(value['pairing'] as Map),
  );
  final cloud = value['cloud'] as Map;
  if (pairing.device.deviceId != qr.hostDeviceId ||
      pairing.device.identityFingerprint != qr.certSha256 ||
      pairing.gatewayUrl.path != '/remote/v1/gateway' ||
      cloud['host'] != qr.hostDeviceId ||
      cloud['hostPublicKey'] != qr.hostPublicKey ||
      cloud['serviceUrl'] != qr.serviceUrl.toString() ||
      cloud['client'] is! String ||
      (cloud['client'] as String).isEmpty ||
      cloud['token'] is! String ||
      (cloud['token'] as String).length < 32) {
    throw const FormatException(
      'Pairing identity or cloud authorization mismatch',
    );
  }
  return value;
}
