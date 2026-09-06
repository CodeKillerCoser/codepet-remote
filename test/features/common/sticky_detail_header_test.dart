import 'package:codepet_remote/features/common/sticky_detail_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pins within the process and keeps the pinned header tappable', (tester) async {
    final controller = ScrollController();
    var taps = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ListView(
      controller: controller,
      children: [
        const SizedBox(height: 100),
        StickyDetailHeader(
          header: GestureDetector(
            key: const Key('header'),
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(height: 40, child: Text('收起')),
          ),
          content: const SizedBox(height: 1000),
        ),
        const SizedBox(height: 1000),
      ],
    ))));
    final header = find.byKey(const Key('header'));
    expect(tester.getTopLeft(header).dy, 100);
    controller.jumpTo(400);
    await tester.pump();
    expect(tester.getTopLeft(header).dy, 0);
    await tester.tap(header);
    expect(taps, 1);
    controller.jumpTo(1120);
    await tester.pump();
    expect(tester.getTopLeft(header).dy, -20);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
