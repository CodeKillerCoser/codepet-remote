import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';

import '../application/ports/application_log.dart';
import 'local_log_store.dart';
import 'log_context.dart';
import 'log_line.dart';

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
      final entry = record.object is _LogEntry
          ? record.object as _LogEntry
          : null;
      final structured = record.object is StructuredLogEvent
          ? record.object as StructuredLogEvent
          : null;
      final payload = <String, Object?>{
        'timestamp': record.time.toUtc().toIso8601String(),
        'level': record.level.name,
        'logger': record.loggerName,
        if (structured == null)
          'message': _redact(record.message.toString())
        else ...{
          'recordType': structured.event == 'span' ? 'trace' : 'event',
          'event': structured.event,
          ..._redactFields(structured.fields),
        },
        if (record.error != null) 'error': _redact(record.error.toString()),
        if (record.stackTrace != null)
          'stackTrace': _redact(record.stackTrace.toString()),
        // Authoritative provenance cannot be overridden by event fields.
        ...(structured?.context ??
            entry?.context ??
            LogContext.capture(StackTrace.current)),
      };
      if (kDebugMode) {
        debugPrint(formatLogLine(payload));
      }
      unawaited(
        target.writeRecord(payload).catchError((Object error) {
          debugPrint('Unable to persist application log: $error');
        }),
      );
    });
    named('app').info('Local diagnostics initialized');
    named('app').event('app.start', {
      'buildRevision': const String.fromEnvironment(
        'CODEPET_BUILD_REVISION',
        defaultValue: 'unknown',
      ),
      'buildMode': kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug',
      'platform': defaultTargetPlatform.name,
      'utcOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes,
    });
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
      named('diagnostics')
          .warning('Log export failed', error: error, stackTrace: stackTrace);
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
  void fine(String message) => _write(Level.FINE, message);

  @override
  void info(String message) => _write(Level.INFO, message);

  @override
  void structured(String event, Map<String, Object?> fields) =>
      _write(Level.FINE, StructuredLogEvent(event, fields));

  void event(
    String event,
    Map<String, Object?> fields, {
    Level level = Level.INFO,
  }) => _write(level, StructuredLogEvent(event, fields));

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) =>
      _write(Level.WARNING, message, error, stackTrace);

  @override
  void severe(String message, {Object? error, StackTrace? stackTrace}) =>
      _write(Level.SEVERE, message, error, stackTrace);

  void _write(
    Level level,
    Object value, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    if (!_logger.isLoggable(level)) return;
    final context = LogContext.capture(StackTrace.current);
    _logger.log(
      level,
      value is StructuredLogEvent
          ? StructuredLogEvent(value.event, value.fields, context: context)
          : _LogEntry(value, context),
      error,
      stackTrace,
    );
  }
}

final class _LogEntry {
  const _LogEntry(this.value, this.context);
  final Object value;
  final Map<String, Object?> context;
  @override
  String toString() => value.toString();
}

final class StructuredLogEvent {
  const StructuredLogEvent(this.event, this.fields, {this.context = const {}});

  final String event;
  final Map<String, Object?> fields;
  final Map<String, Object?> context;

  @override
  String toString() => event;
}

Map<String, Object?> _redactFields(Map<String, Object?> fields) => {
  for (final entry in fields.entries)
    entry.key: switch (entry.value) {
      final String value => _redact(value),
      final Map<String, Object?> value => _redactFields(value),
      _ => entry.value,
    },
};

String _redact(String value) => value
    .replaceAll(
      RegExp(r'Bearer\s+[^\s,}]+', caseSensitive: false),
      'Bearer [REDACTED]',
    )
    .replaceAll(
      RegExp(
        r'("(?:credential|pairingSecret|clientNonce)"\s*:\s*")[^"]*(")',
        caseSensitive: false,
      ),
      r'$1[REDACTED]$2',
    );
