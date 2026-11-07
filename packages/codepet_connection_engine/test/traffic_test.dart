import 'package:test/test.dart';
import 'package:codepet_connection_engine/codepet_connection_engine.dart';

void main() {
  test('bounded window, idle decay, totals and negative rejection', () {
    var now = 0;
    final meter = TrafficMeter(nowMilliseconds: () => now);
    for (var i = 0; i < 100000; i++) {
      now += 100;
      meter.record(sent: 1, received: 2);
      expect(meter.bucketCount, lessThanOrEqualTo(30));
    }
    expect(meter.snapshot.totalBytes, 300000);
    expect(meter.snapshot.sentBytesPerSecond, 10);
    now += 3000;
    expect(meter.snapshot.sentBytesPerSecond, 0);
    expect(meter.snapshot.totalBytes, 300000);
    expect(() => meter.record(sent: -1), throwsArgumentError);
  });
}
