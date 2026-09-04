abstract interface class TraceRecorder {
  TraceCorrelation? get currentContext;

  Future<T> trace<T>(
    String name,
    Future<T> Function(TraceCorrelation? context) operation, {
    Map<String, Object?> attributes = const {},
  });

  T runWithContext<T>(TraceCorrelation? context, T Function() operation);

  void instant(
    String name, {
    TraceCorrelation? context,
    Map<String, Object?> attributes = const {},
  });
}

final class TraceCorrelation {
  const TraceCorrelation({
    required this.traceId,
    required this.spanId,
    this.parentSpanId,
    this.sampled = true,
    this.traceState,
  });

  final String traceId;
  final String spanId;
  final String? parentSpanId;
  final bool sampled;
  final String? traceState;

  String get traceparent =>
      '00-$traceId-$spanId-${sampled ? '01' : '00'}';

  static TraceCorrelation? tryParse(String traceparent, {String? traceState}) {
    final parts = traceparent.split('-');
    if (parts.length != 4 ||
        parts[0].length != 2 ||
        parts[1].length != 32 ||
        parts[2].length != 16 ||
        parts[3].length != 2 ||
        !_lowerHex.hasMatch(traceparent) ||
        parts[1] == '00000000000000000000000000000000' ||
        parts[2] == '0000000000000000') {
      return null;
    }
    return TraceCorrelation(
      traceId: parts[1],
      spanId: parts[2],
      sampled: (int.parse(parts[3], radix: 16) & 1) == 1,
      traceState: traceState,
    );
  }
}

final RegExp _lowerHex = RegExp(r'^[0-9a-f-]+$');

class NoopTraceRecorder implements TraceRecorder {
  const NoopTraceRecorder();

  @override
  TraceCorrelation? get currentContext => null;

  @override
  void instant(
    String name, {
    TraceCorrelation? context,
    Map<String, Object?> attributes = const {},
  }) {}

  @override
  T runWithContext<T>(TraceCorrelation? context, T Function() operation) =>
      operation();

  @override
  Future<T> trace<T>(
    String name,
    Future<T> Function(TraceCorrelation? context) operation, {
    Map<String, Object?> attributes = const {},
  }) => operation(null);
}
