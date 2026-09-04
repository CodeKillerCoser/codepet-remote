import 'dart:async';
import 'dart:math';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:codepet_remote/application/ports/application_log.dart';
import 'package:codepet_remote/diagnostics/app_trace_recorder.dart';
import 'package:codepet_remote/diagnostics/gateway_protocol_instrumentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('isolates concurrent Zone trace contexts', () async {
    final log = _CapturingLog();
    final recorder = AppTraceRecorder(
      logger: log,
      random: Random(7),
      processInstanceId: 'test-process',
    );
    final barrier = Completer<void>();
    late String firstTrace;
    late String secondTrace;

    final first = recorder.trace('first', (context) async {
      firstTrace = context!.traceId;
      await barrier.future;
      expect(recorder.currentContext?.traceId, firstTrace);
    });
    final second = recorder.trace('second', (context) async {
      secondTrace = context!.traceId;
      barrier.complete();
      await Future<void>.delayed(Duration.zero);
      expect(recorder.currentContext?.traceId, secondTrace);
    });

    await Future.wait([first, second]);
    expect(firstTrace, isNot(secondTrace));
    expect(recorder.currentContext, isNull);
    expect(log.records, hasLength(2));
  });

  test('injects trace context only after protocol feature discovery', () async {
    final recorder = AppTraceRecorder(
      logger: _CapturingLog(),
      random: Random(9),
      processInstanceId: 'test-process',
    );
    final instrumentation = GatewayProtocolInstrumentation(recorder);
    sdk.TraceContext? before;
    sdk.TraceContext? after;

    await instrumentation.traceRequest<void>(
      method: sdk.ProtocolMethod.turnSend,
      requestId: 'before',
      invoke: (context) async => before = context,
    );
    instrumentation.wirePropagationEnabled = true;
    await instrumentation.traceRequest<void>(
      method: sdk.ProtocolMethod.turnSend,
      requestId: 'after',
      invoke: (context) async => after = context,
    );

    expect(before, isNull);
    expect(after?.traceparent, matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')));
  });
}

final class _CapturingLog implements ApplicationLog {
  final List<Map<String, Object?>> records = [];

  @override
  void structured(String event, Map<String, Object?> fields) {
    records.add({'event': event, ...fields});
  }

  @override
  void fine(String message) {}

  @override
  void info(String message) {}

  @override
  void severe(String message, {Object? error, StackTrace? stackTrace}) {}

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) {}
}
