import 'package:codepet_remote/ui/components/app_settings_section.dart';
import 'package:codepet_remote/ui/components/app_switch_tile.dart';
import 'package:codepet_remote/ui/layout/app_layout.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('all section headings use the same content and group spacing', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: Scaffold(
      body: Column(children: [
        for (var i = 0; i < 3; i++)
          AppSettingsSection(
            key: Key('section-$i'),
            title: '分区 $i',
            children: [ListTile(title: Text('选项 $i'))],
          ),
      ]),
    )));
    Rect? previousSurface;
    for (var i = 0; i < 3; i++) {
      final title = tester.getRect(find.text('分区 $i'));
      final surface = tester.getRect(find.descendant(
        of: find.byKey(Key('section-$i')), matching: find.byType(Material),
      ).first);
      expect(surface.top - title.bottom, closeTo(AppLayout.gap, .01));
      if (previousSurface != null) {
        expect(title.top - previousSurface.bottom, closeTo(AppLayout.sectionGap, .01));
      }
      previousSurface = surface;
    }
  });

  testWidgets('compact switch retains touch height and row toggles exactly once', (tester) async {
    var value = false;
    var calls = 0;
    await tester.pumpWidget(MaterialApp(theme: AppTheme.light, home: Scaffold(
      body: StatefulBuilder(builder: (context, setState) => AppSwitchTile(
        title: const Text('任务结果'),
        value: value,
        onChanged: (next) => setState(() { value = next; calls++; }),
      )),
    )));
    expect(tester.getSize(find.byType(Switch)).height, greaterThanOrEqualTo(48));
    await tester.tap(find.text('任务结果'));
    await tester.pumpAndSettle();
    expect(value, isTrue);
    expect(calls, 1);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(value, isFalse);
    expect(calls, 2);
    expect(tester.takeException(), isNull);
  });
}
