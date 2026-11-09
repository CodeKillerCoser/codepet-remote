import 'package:codepet_remote/ui/layout/app_scaffold.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('page frame keeps bottom actions compact, dark=$dark', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          home: const AppScaffold(
            body: SizedBox.expand(key: Key('content')),
            bottomNavigationBar: SizedBox(height: 60, key: Key('actions')),
          ),
        ),
      );
      expect(tester.getSize(find.byKey(const Key('content'))).width, 960);
      expect(
        tester.getSize(find.byKey(const Key('content'))).height,
        greaterThan(800),
      );
      expect(tester.getSize(find.byKey(const Key('actions'))).height, 60);
      final theme = Theme.of(tester.element(find.byKey(const Key('content'))));
      expect(theme.brightness, dark ? Brightness.dark : Brightness.light);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow page preserves large system text and scrollability', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: AppScaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            children: List.generate(
              12,
              (i) => ListTile(
                title: Text('设置项目 $i'),
                subtitle: const Text('较长的说明保持自然换行，遵循系统字号。'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      MediaQuery.textScalerOf(tester.element(find.text('设置项目 0'))).scale(16),
      32,
    );
    await tester.scrollUntilVisible(find.text('设置项目 11'), 300);
    expect(find.text('设置项目 11'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
