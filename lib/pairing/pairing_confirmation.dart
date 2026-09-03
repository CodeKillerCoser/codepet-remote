import 'dart:convert';

import 'package:crypto/crypto.dart';

String derivePairingConfirmationCode({
  required String requestId,
  required String clientNonce,
  required String certificateFingerprint,
}) {
  final digest = sha256
      .convert(
        utf8.encode(
          '$requestId\u0000$clientNonce\u0000$certificateFingerprint',
        ),
      )
      .bytes;
  final value = ((digest[0] << 24) |
          (digest[1] << 16) |
          (digest[2] << 8) |
          digest[3]) %
      1000000;
  return value.toString().padLeft(6, '0');
}
