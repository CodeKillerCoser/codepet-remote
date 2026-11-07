import 'dart:collection';

import '../core/domain/connection_traffic.dart';

/// Bounded 100 ms buckets over a 3 second window, independent of UI polling.
class ConnectionTrafficMeter {
  ConnectionTrafficMeter({this.channel = 'unknown', int Function()? clock}) {
    final stopwatch = Stopwatch()..start();
    _clock = clock ?? (() => stopwatch.elapsedMilliseconds);
    _started = _clock();
  }
  late final int Function() _clock;
  late final int _started;
  String channel;
  int _sent = 0, _received = 0;
  final _buckets = Queue<_Bucket>();
  void sent(int bytes) => _record(bytes, 0);
  void received(int bytes) => _record(0, bytes);
  void _record(int sent, int received) {
    final tick = (_clock() - _started) ~/ 100;
    _sent += sent;
    _received += received;
    while (_buckets.isNotEmpty && _buckets.first.tick + 30 <= tick) {
      _buckets.removeFirst();
    }
    if (_buckets.isEmpty || _buckets.last.tick != tick) {
      _buckets.add(_Bucket(tick));
    }
    _buckets.last.sent += sent;
    _buckets.last.received += received;
  }

  ConnectionTraffic get snapshot {
    final now = _clock() - _started;
    var sent = 0, received = 0;
    for (final bucket in _buckets) {
      if (bucket.tick + 30 > now ~/ 100) {
        sent += bucket.sent;
        received += bucket.received;
      }
    }
    final seconds = (now / 1000).clamp(0.1, 3.0);
    return ConnectionTraffic(
      channel: channel,
      sentBytes: _sent,
      receivedBytes: _received,
      sentBytesPerSecond: sent / seconds,
      receivedBytesPerSecond: received / seconds,
    );
  }
}

class _Bucket {
  _Bucket(this.tick);
  final int tick;
  int sent = 0, received = 0;
}
