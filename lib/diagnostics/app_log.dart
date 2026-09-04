import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../application/ports/application_log.dart';
import 'local_log_store.dart';

class AppLog implements ApplicationLog {
  AppLog._(this._logger);

  final Logger _logger;
  static LocalLogStore? _store;
  static StreamSubscription<LogRecord>? _subscription;

  static AppLog named(String name) => AppLog._(Logger(name));

  static Future<void> initialize({LocalLogStore? store}) async {
    if (_store != null) return;
    _store = store ?? await LocalLogStore.open();
    Logger.root.level = Level.ALL;
    _subscription = Logger.root.onRecord.listen((record) {
      final target = _store;
      if (target == null) return;
      final line = jsonEncode({
        'timestamp': record.time.toUtc().toIso8601String(),
        'level': record.level.name,
        'logger': record.loggerName,
        'message': _redact(record.message),
        if (record.error != null) 'error': _redact(record.error.toString()),
        if (record.stackTrace != null)
          'stackTrace': _redact(record.stackTrace.toString()),
      });
      if (kDebugMode) {
        debugPrint(
          '${record.level.name} ${record.loggerName}: '
          '${_redact(record.message)}',
        );
      }
      unawaited(target.writeLine(line).catchError((Object error) {
        debugPrint('Unable to persist application log: $error');
      }));
    });
    named('app').info('Local diagnostics initialized');
  }

  static Future<String> exportLogs() async {
    final store = _store;
    if (store == null) {
      throw StateError('Local diagnostics have not been initialized');
    }
    named('diagnostics').info('Log export requested');
    try {
      final path = await store.exportZip();
      named('diagnostics').info('Log export created');
      return path;
    } catch (error, stackTrace) {
      named('diagnostics').warning(
        'Log export failed',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  static Future<void> flush() async {
    await _store?.flush();
  }

  @visibleForTesting
  static Future<void> resetForTesting() async {
    await flush();
    await _subscription?.cancel();
    _subscription = null;
    _store = null;
  }

  @override
  void fine(String message) => _logger.fine(message);

  @override
  void info(String message) => _logger.info(message);

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _logger.warning(message, error, stackTrace);

  @override
  void severe(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) =>
      _logger.severe(message, error, stackTrace);
}

String _redact(String value) => value
    .replaceAll(RegExp(r'Bearer\s+[^\s,}]+', caseSensitive: false), 'Bearer [REDACTED]')
    .replaceAll(
      RegExp(
        r'("(?:credential|pairingSecret|clientNonce)"\s*:\s*")[^"]*(")',
        caseSensitive: false,
      ),
      r'$1[REDACTED]$2',
    );
