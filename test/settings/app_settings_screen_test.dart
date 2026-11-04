import 'package:codepet_remote/features/settings/app_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:codepet_remote/core/domain/notification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('notification preferences default to private opt-in and save each category', (tester) async {
    NotificationPreferences? saved;
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(
      exportLogs: () async => 'logs', notificationPreferences: const NotificationPreferences(),
      notificationsAllowed: () async => true,
      onNotificationsChanged: (value) async { saved = value; return value; },
    )));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('notification-preview'))).value, isFalse);
    await tester.tap(find.byKey(const Key('notification-outcomes')));
    await tester.pumpAndSettle();
    expect(saved?.outcomes, isTrue);
    expect(saved?.interventions, isFalse);
    expect(saved?.preview, isFalse);
    expect(saved?.keepConnected, isFalse);
  });

  testWidgets('permission rejection leaves notification toggle off', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(
      exportLogs: () async => 'logs', notificationPreferences: const NotificationPreferences(),
      notificationsAllowed: () async => false,
      onNotificationsChanged: (_) => Future.error(StateError('permission denied')),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('notification-interventions')));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byKey(const Key('notification-interventions'))).value, isFalse);
    expect(find.text('无法开启，请检查系统通知权限后重试'), findsOneWidget);
  });

  testWidgets('exports logs and exposes the local archive path', (tester) async {
    var exportCalls = 0;
    await tester.pumpWidget(MaterialApp(
      home: AppSettingsScreen(
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
        exportLogs: () => Future.error(StateError('disk unavailable')),
      ),
    ));

    await tester.tap(find.byKey(const Key('export-logs')));
    await tester.pumpAndSettle();

    expect(find.textContaining('日志导出失败'), findsOneWidget);
    expect(find.byKey(const Key('share-logs')), findsNothing);
  });
}
