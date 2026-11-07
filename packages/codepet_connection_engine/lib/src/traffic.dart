import 'dart:collection';

final class TrafficSnapshot {
  const TrafficSnapshot({
    this.sentBytes = 0,
    this.receivedBytes = 0,
    this.sentBytesPerSecond = 0,
    this.receivedBytesPerSecond = 0,
  });
  final int sentBytes, receivedBytes;
  final double sentBytesPerSecond, receivedBytesPerSecond;
  int get totalBytes => sentBytes + receivedBytes;
}

/// Per-physical-connection application bytes. Constant bounded storage; no UI,
/// timer, protocol or OS dependency. Time must be monotonic.
final class TrafficMeter {
  TrafficMeter({int Function()? nowMilliseconds}) {
    final clock = Stopwatch()..start();
    _now = nowMilliseconds ?? () => clock.elapsedMilliseconds;
    _start = _now();
  }
  late final int Function() _now;
  late final int _start;
  int _sent = 0, _received = 0;
  final _buckets = Queue<_Bucket>();
  int get bucketCount => _buckets.length;
  void record({int sent = 0, int received = 0}) {
    if (sent < 0 || received < 0) throw ArgumentError('Negative byte count');
    final tick = (_now() - _start) ~/ 100;
    _prune(tick);
    _sent += sent;
    _received += received;
    if (_buckets.isEmpty || _buckets.last.tick != tick) {
      _buckets.add(_Bucket(tick));
    }
    _buckets.last.sent += sent;
    _buckets.last.received += received;
  }

  void _prune(int tick) {
    while (_buckets.isNotEmpty && _buckets.first.tick + 30 <= tick) {
      _buckets.removeFirst();
    }
  }

  TrafficSnapshot get snapshot {
    final elapsed = _now() - _start;
    _prune(elapsed ~/ 100);
    final seconds = (elapsed / 1000).clamp(0.1, 3.0);
    return TrafficSnapshot(
      sentBytes: _sent,
      receivedBytes: _received,
      sentBytesPerSecond: _buckets.fold<int>(0, (v, b) => v + b.sent) / seconds,
      receivedBytesPerSecond:
          _buckets.fold<int>(0, (v, b) => v + b.received) / seconds,
    );
  }
}

final class _Bucket {
  _Bucket(this.tick);
  final int tick;
  int sent = 0, received = 0;
}
