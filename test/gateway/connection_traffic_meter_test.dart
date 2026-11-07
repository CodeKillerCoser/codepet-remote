import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/gateway/connection_traffic_meter.dart';

void main() {
  test(
    'three second rate expires, connection totals and byte directions survive',
    () {
      var now = 0;
      final meter = ConnectionTrafficMeter(
        channel: 'ipv6-direct',
        clock: () => now,
      );
      now = 500;
      meter.sent(300);
      now = 1000;
      meter.received(900);
      now = 1500;
      expect(meter.snapshot.sentBytesPerSecond, 200);
      expect(meter.snapshot.receivedBytesPerSecond, 600);
      now = 5000;
      expect(meter.snapshot.totalBytes, 1200);
      expect(meter.snapshot.sentBytesPerSecond, 0);
      expect(meter.snapshot.receivedBytesPerSecond, 0);
      final reconnect = ConnectionTrafficMeter();
      expect(reconnect.snapshot.totalBytes, 0);
    },
  );
}
