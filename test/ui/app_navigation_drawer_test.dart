import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:codepet_remote/ui/components/app_navigation_drawer.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('selection and text share the overscroll transform', (tester) async {
    const captureKey = Key('capture');
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.light,
      home: Scaffold(body: RepaintBoundary(
        key: captureKey,
        child: ScrollConfiguration(behavior: const _OverscrollTransform(), child: SizedBox(width: 300, height: 500, child: AppNavigationDrawer(
          title: 'CodePet', subtitle: '设备',
          footer: const ListTile(title: Text('设置')),
          children: List.generate(10, (i) => ListTile(
            key: Key('row-$i'), selected: i == 2, title: Text('设备 $i', style: i == 2 ? const TextStyle(color: Color(0xFFFF00FF)) : null),
          )),
        ))),
      )),
    ));
    await tester.pumpAndSettle();
    // The ink owner must be inside the list, so scroll/overscroll transforms
    // and viewport clipping apply to selection as well as the row's content.
    final materials = find.ancestor(
      of: find.byKey(const Key('row-2')), matching: find.byType(Material),
    );
    final inkOwner = tester.element(materials.first);
    expect(inkOwner.findAncestorWidgetOfExactType<ListView>(), isNotNull);
    final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      final selected = AppTheme.light.listTileTheme.selectedTileColor!.toARGB32();
      var fillTop = image.height, fillBottom = -1;
      var textTop = image.height, textBottom = -1;
      for (var y = 0; y < image.height; y++) {
        for (var x = 0; x < image.width; x++) {
          final offset = (y * image.width + x) * 4;
          final color = Color.fromARGB(bytes.getUint8(offset + 3),
              bytes.getUint8(offset), bytes.getUint8(offset + 1), bytes.getUint8(offset + 2)).toARGB32();
          if (color == selected) {
            if (y < fillTop) fillTop = y;
            if (y > fillBottom) fillBottom = y;
          }
          if (color == 0xFFFF00FF) {
            if (y < textTop) textTop = y;
            if (y > textBottom) textBottom = y;
          }
        }
      }
      expect(textBottom, greaterThanOrEqualTo(0));
      expect(fillTop, lessThanOrEqualTo(textTop));
      expect(fillBottom, greaterThanOrEqualTo(textBottom));
      image.dispose();
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('drawer supports large text and scrolling in ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: brightness == Brightness.dark ? AppTheme.dark : AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          drawer: AppNavigationDrawer(
            title: 'CodePet',
            subtitle: '你的 AI 工作空间',
            footer: ListTile(
              key: const Key('settings'),
              title: const Text('设置'),
              leading: const Icon(Icons.settings_outlined),
              onTap: () {},
            ),
            children: List.generate(20, (i) => ListTile(
              title: Text('设备 $i', maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: const Text('Mac OS · 在线', maxLines: 1, overflow: TextOverflow.ellipsis),
              leading: const Icon(Icons.computer),
              selected: i == 0,
            )),
          ),
          body: const SizedBox(),
        ),
      ));
      tester.state<ScaffoldState>(find.byType(Scaffold)).openDrawer();
      await tester.pumpAndSettle();
      final footer = find.byKey(const Key('settings'));
      final position = tester.getTopLeft(footer);
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(footer), position);
      expect(footer.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}


// Models the paint transform used by stretch overscroll. Its descendants must
// paint their ink inside the transformed subtree, not on Drawer's Material.
class _OverscrollTransform extends MaterialScrollBehavior {
  const _OverscrollTransform();
  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) =>
      Transform.translate(offset: const Offset(0, -60), child: child);
}
