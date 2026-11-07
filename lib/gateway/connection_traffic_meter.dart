import 'package:codepet_connection_engine/codepet_connection_engine.dart' as engine;
import '../core/domain/connection_traffic.dart';

/// Domain adapter; bounded accounting lives in the independently tested engine.
class ConnectionTrafficMeter {
  ConnectionTrafficMeter({this.channel = 'unknown', int Function()? clock})
      : _meter = engine.TrafficMeter(nowMilliseconds: clock);
  final engine.TrafficMeter _meter;
  String channel;
  void sent(int bytes) => _meter.record(sent: bytes);
  void received(int bytes) => _meter.record(received: bytes);
  ConnectionTraffic get snapshot {
    final value = _meter.snapshot;
    return ConnectionTraffic(
      channel: channel, sentBytes: value.sentBytes,
      receivedBytes: value.receivedBytes,
      sentBytesPerSecond: value.sentBytesPerSecond,
      receivedBytesPerSecond: value.receivedBytesPerSecond,
    );
  }
}
