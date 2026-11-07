import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/core/domain/connection_traffic.dart';
import 'package:codepet_remote/features/connection/connection_traffic_view.dart';

void main() {
  testWidgets('compact metrics stay left aligned and stable across units', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();
    ConnectionTraffic? traffic = const ConnectionTraffic(
      channel: 'ipv6-direct',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ConnectionTrafficView(
                  read: () => traffic,
                  compact: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    final channel = find.text('IPv6 直连');
    final metrics = [
      'traffic-upload',
      'traffic-download',
      'traffic-total',
    ].map((key) => find.byKey(Key(key))).toList();
    expect(tester.getTopLeft(channel).dx, 16);
    final original = metrics.map(tester.getRect).toList();
    for (final rect in original) {
      expect(rect.center.dy, closeTo(tester.getCenter(channel).dy, 1));
    }
    expect(find.textContaining('累计'), findsNothing);
    expect(find.textContaining('上传'), findsNothing);
    expect(find.textContaining('下载'), findsNothing);
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
    for (final bytes in [
      9,
      999,
      1023,
      1024,
      10240,
      99.96 * 1024,
      1048575,
      1048576,
      1073741824,
    ]) {
      traffic = ConnectionTraffic(
        channel: 'ipv6-direct',
        sentBytes: bytes.round(),
        sentBytesPerSecond: bytes.toDouble(),
        receivedBytesPerSecond: bytes.toDouble(),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(metrics.map(tester.getRect).toList(), original);
      expect(tester.takeException(), isNull);
    }
    expect(find.bySemanticsLabel('上传速度 1.0 GiB每秒'), findsOneWidget);
    expect(find.bySemanticsLabel('本次连接传输数据量 1.0 GiB'), findsOneWidget);

    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pump();
    final narrow = metrics.map(tester.getRect).toList();
    for (final rect in narrow) {
      expect(rect.left, greaterThanOrEqualTo(16));
      expect(rect.right, lessThanOrEqualTo(304));
    }
    traffic = const ConnectionTraffic(channel: 'ipv6-direct', sentBytes: 9);
    await tester.pump(const Duration(seconds: 1));
    expect(metrics.map(tester.getRect).toList(), narrow);
    expect(tester.takeException(), isNull);
    traffic = null;
    await tester.pump(const Duration(seconds: 1));
    expect(channel, findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets(
    'traffic wraps at phone width, refreshes and removes stale connection data',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ConnectionTraffic? traffic = const ConnectionTraffic(
        channel: 'ipv6-direct',
        sentBytes: 1024,
        receivedBytes: 2048,
        receivedBytesPerSecond: 512,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: ConnectionTrafficView(read: () => traffic),
            ),
          ),
        ),
      );
      expect(find.text('IPv6 直连'), findsOneWidget);
      expect(find.text('本次连接 3.0 KiB'), findsOneWidget);
      expect(tester.takeException(), isNull);
      traffic = const ConnectionTraffic(channel: 'relay', sentBytes: 4096);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('中继'), findsOneWidget);
      expect(find.text('↓ 0 B/s'), findsOneWidget);
      traffic = null;
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('中继'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
