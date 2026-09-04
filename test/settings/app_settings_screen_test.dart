import 'package:codepet_remote/features/settings/app_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exports logs and exposes the local archive path', (tester) async {
    var exportCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: AppSettingsScreen(
        sessions: const [],
        onForgetDevice: (_) async {},
        exportLogs: () async {
          exportCalls++;
          return '/local/diagnostics/codepet-logs.zip';
        },
      ),
    ));

    expect(find.textContaining('日志保留 7 天'), findsOneWidget);
    await tester.tap(find.byKey(const Key('export-logs')));
    await tester.pumpAndSettle();

    expect(exportCalls, 1);
    expect(
      find.text('/local/diagnostics/codepet-logs.zip'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('share-logs')), findsOneWidget);
    expect(find.text('日志压缩包已生成'), findsOneWidget);
  });

  testWidgets('shows export failures without exposing a share action',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: AppSettingsScreen(
        sessions: const [],
        onForgetDevice: (_) async {},
        exportLogs: () => Future.error(StateError('disk unavailable')),
      ),
    ));

    await tester.tap(find.byKey(const Key('export-logs')));
    await tester.pumpAndSettle();

    expect(find.textContaining('日志导出失败'), findsOneWidget);
    expect(find.byKey(const Key('share-logs')), findsNothing);
  });
}
