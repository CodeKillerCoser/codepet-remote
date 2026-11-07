import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../application/errors/application_failures.dart';

/// One device connection's short-lived ICE credentials. Parallel candidates and
/// reconnect rounds share a request, never a PeerConnection or TURN allocation.
/// No credentials are persisted or logged. Authorization changes replace the
/// entry; invalidation also prevents an older in-flight request repopulating it.
final class IceConfigurationCache {
  IceConfigurationCache({DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  _Entry? _entry;
  static const _maxAge = Duration(minutes: 1);
  static const _expiryMargin = Duration(minutes: 1);

  String _key(Map<String, dynamic> state) => sha256
      .convert(
        utf8.encode(
          jsonEncode([
            Uri.parse(state['serviceUrl'] as String).normalizePath().toString(),
            state['host'],
            state['client'],
            state['hostPublicKey'],
            state['token'],
          ]),
        ),
      )
      .toString();

  Future<Map<String, dynamic>> load(
    Map<String, dynamic> state,
    Future<Map<String, dynamic>> Function() fetch,
  ) async {
    final key = _key(state);
    var entry = _entry;
    if (entry == null ||
        entry.key != key ||
        (entry.until != null && !_now().isBefore(entry.until!))) {
      entry = _Entry(key);
      _entry = entry;
      // Attach failure handling immediately, including synchronous fetch errors.
      entry.pending = _fetch(entry, fetch);
    }
    // Each caller owns a copy; filtering one path cannot alter another's ICE list.
    return Map<String, dynamic>.from(jsonDecode(await entry.pending) as Map);
  }

  Future<String> _fetch(
    _Entry entry,
    Future<Map<String, dynamic>> Function() fetch,
  ) async {
    try {
      final value = await fetch();
      final expiry = value['expires'];
      if (expiry is! int || value['iceServers'] is! List) {
        throw const FormatException('Invalid ICE configuration');
      }
      final now = _now();
      final usableUntil = DateTime.fromMillisecondsSinceEpoch(expiry * 1000)
          .subtract(_expiryMargin);
      if (!now.isBefore(usableUntil)) {
        throw const GatewayConnectionException(
          'ICE credentials expire too soon',
          retryable: true,
        );
      }
      final refresh = now.add(_maxAge);
      entry.until = refresh.isBefore(usableUntil) ? refresh : usableUntil;
      return jsonEncode(value);
    } catch (_) {
      if (identical(_entry, entry)) _entry = null;
      rethrow;
    }
  }

  void invalidate(Map<String, dynamic> state) {
    if (_entry?.key == _key(state)) _entry = null;
  }
}

final class _Entry {
  _Entry(this.key);
  final String key;
  late final Future<String> pending;
  DateTime? until;
}
