import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/core/domain/connection_traffic.dart';
import 'package:codepet_remote/features/connection/connection_traffic_view.dart';

void main() {
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
