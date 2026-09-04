import 'dart:async';
import 'dart:math';

import '../application/ports/application_log.dart';
import '../application/ports/trace_recorder.dart';

final Object _traceZoneKey = Object();

final class AppTraceRecorder implements TraceRecorder {
  factory AppTraceRecorder({
    required ApplicationLog logger,
    Random? random,
    String? processInstanceId,
  }) {
    final effectiveRandom = random ?? Random.secure();
    return AppTraceRecorder._(
      logger,
      effectiveRandom,
      processInstanceId ?? _randomHex(effectiveRandom, 16),
    );
  }

  AppTraceRecorder._(this._logger, this._random, this.processInstanceId);

  final ApplicationLog _logger;
  final Random _random;
  final String processInstanceId;

  @override
  TraceCorrelation? get currentContext =>
      Zone.current[_traceZoneKey] as TraceCorrelation?;

  @override
  Future<T> trace<T>(
    String name,
    Future<T> Function(TraceCorrelation? context) operation, {
    Map<String, Object?> attributes = const {},
  }) async {
    final parent = currentContext;
    final context = TraceCorrelation(
      traceId: parent?.traceId ?? _randomHex(_random, 16),
      spanId: _randomHex(_random, 8),
      parentSpanId: parent?.spanId,
      sampled: parent?.sampled ?? true,
      traceState: parent?.traceState,
    );
    final startedAt = DateTime.now().toUtc();
    final stopwatch = Stopwatch()..start();
    Object? failure;
    try {
      return await runZoned(
        () => operation(context),
        zoneValues: {_traceZoneKey: context},
      );
    } catch (error) {
      failure = error;
      rethrow;
    } finally {
      _logger.structured('span', {
        'schema': 'codepet.trace.v1',
        'service': 'remote',
        'processInstanceId': processInstanceId,
        'name': name,
        'traceId': context.traceId,
        'spanId': context.spanId,
        if (context.parentSpanId != null) 'parentSpanId': context.parentSpanId,
        'startedAt': startedAt.toIso8601String(),
        'durationUs': stopwatch.elapsedMicroseconds,
        'status': failure == null ? 'ok' : 'error',
        ...attributes,
      });
    }
  }

  @override
  T runWithContext<T>(TraceCorrelation? context, T Function() operation) {
    if (context == null) return operation();
    return runZoned(
      operation,
      zoneValues: {_traceZoneKey: context},
    );
  }

  @override
  void instant(
    String name, {
    TraceCorrelation? context,
    Map<String, Object?> attributes = const {},
  }) {
    final effective = context ?? currentContext;
    _logger.structured('event', {
      'schema': 'codepet.trace.v1',
      'service': 'remote',
      'processInstanceId': processInstanceId,
      'name': name,
      if (effective != null) ...{
        'traceId': effective.traceId,
        'spanId': effective.spanId,
      },
      ...attributes,
    });
  }
}

String _randomHex(Random random, int byteCount) {
  final buffer = StringBuffer();
  for (var index = 0; index < byteCount; index++) {
    buffer.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
