import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../application/errors/application_failures.dart';
import '../../core/domain/signaling_service.dart';
import '../../diagnostics/app_log.dart';

/// Enrollment identifies an installation; it grants no Host or TURN access.
class SignalingDeviceRegistration {
  SignalingDeviceRegistration({
    required this.deviceId,
    Future<String?> Function(String)? read,
    Future<void> Function(String, String)? write,
    Future<Map<String, dynamic>> Function(Uri, Map<String, dynamic>)? post,
  }) : _read = read ?? ((key) => _storage.read(key: key)),
       _write =
           write ?? ((key, value) => _storage.write(key: key, value: value)),
       _post = post ?? _request;
  static const _storage = FlutterSecureStorage(aOptions: AndroidOptions());
  final Future<String> Function() deviceId;
  final Future<String?> Function(String) _read;
  final Future<void> Function(String, String) _write;
  final Future<Map<String, dynamic>> Function(Uri, Map<String, dynamic>) _post;
  Future<void> _pending = Future.value();
  String? _registered;

  Future<void> register(String address, {bool force = false}) {
    final operation = _pending.then((_) => _register(address, force));
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _register(String address, bool force) async {
    final service = normalizeSignalingService(address);
    if (service == null || (!force && service == _registered)) return;
    final log = AppLog.named('gateway.registration');
    log.structured('signal.registration.start', {'role': 'remote'});
    try {
      final random = Random.secure();
      const identityKey = 'signal_device_key_v1';
      var seed = await _read(identityKey);
      if (seed == null) {
        seed = base64Encode(List.generate(32, (_) => random.nextInt(256)));
        await _write(identityKey, seed);
      }
      final grantKey =
          'signal_grant_${hashes.sha256.convert(utf8.encode(service))}';
      var token = await _read(grantKey);
      if (token == null) {
        token = base64Encode(List.generate(32, (_) => random.nextInt(256)));
        await _write(grantKey, token);
      }
      final id = await deviceId();
      final key = await Ed25519().newKeyPairFromSeed(base64Decode(seed));
      final payload = utf8.encode(
        jsonEncode({
          'v': 1,
          'kind': 'device.register',
          'deviceId': id,
          'role': 'remote',
          'tokenHash': hashes.sha256.convert(utf8.encode(token)).toString(),
          'expires': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 60,
        }),
      );
      final result = await _post(Uri.parse('$service/v1/devices/register'), {
        'payload': base64Encode(payload),
        'signature': base64Encode(
          (await Ed25519().sign(payload, keyPair: key)).bytes,
        ),
        'publicKey': base64Encode((await key.extractPublicKey()).bytes),
      });
      if (result['protocol'] != 'codepet-device-registration-v1' ||
          result['deviceId'] != id ||
          result['role'] != 'remote' ||
          result['status'] != 'registered') {
        throw const SignalingRegistrationException('信令服务返回的登记信息无效');
      }
      _registered = service;
      log.structured('signal.registration.complete', {'role': 'remote'});
    } catch (error) {
      log.structured('signal.registration.failed', {
        'role': 'remote',
        'type': error.runtimeType.toString(),
      });
      if (error is SignalingRegistrationException) rethrow;
      throw const SignalingRegistrationException('地址已保存，设备登记暂未成功，App 将自动重试');
    }
  }

  static Future<Map<String, dynamic>> _request(
    Uri uri,
    Map<String, dynamic> body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      return await (() async {
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
        final response = await request.close();
        if (response.statusCode != 200) {
          AppLog.named('gateway.registration').structured(
            'signal.registration.rejected',
            {'status': response.statusCode},
          );
          throw SignalingRegistrationException(switch (response.statusCode) {
            403 || 404 => '信令服务尚未启用自动登记，请更新服务端',
            409 => '设备登记身份冲突，原有身份不会被覆盖',
            429 => '登记请求过于频繁，App 将稍后重试',
            _ => '地址已保存，信令服务登记失败，App 将自动重试',
          });
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 16384) {
            throw const FormatException();
          }
          bytes.addAll(chunk);
        }
        return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
      })().timeout(const Duration(seconds: 15));
    } finally {
      client.close(force: true);
    }
  }
}
