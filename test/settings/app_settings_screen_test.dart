import 'dart:async';

import 'package:codepet_remote/features/settings/app_settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:codepet_remote/core/domain/notification.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
  final shareCalls = <MethodCall>[];
  late Future<Object?> Function(MethodCall) shareResult;
  setUp(() {
    shareCalls.clear();
    shareResult = (_) async => 'com.tencent.mm';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, (call) async {
          shareCalls.add(call);
          return shareResult(call);
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, null);
  });
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

  testWidgets('export immediately opens native sharing with the ZIP attachment', (tester) async {
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
    expect(shareCalls, hasLength(1));
    expect(shareCalls.single.method, 'share');
    expect(shareCalls.single.arguments['paths'], ['/local/diagnostics/codepet-logs.zip']);
    expect(shareCalls.single.arguments['mimeTypes'], ['application/zip']);
    expect(shareCalls.single.arguments['subject'], 'CodePet Remote 诊断日志');
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
    expect(shareCalls, isEmpty);
  });

  testWidgets('cancelled share keeps a visible retry action on a small notification settings page', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    shareResult = (_) async => 'dev.fluttercommunity.plus/share/dismissed';
    var exports = 0;
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(
      notificationPreferences: const NotificationPreferences(),
      notificationsAllowed: () async => false,
      exportLogs: () async {
        exports++;
        return '/data/user/0/com.codepet.remote/cache/diagnostics/codepet-logs-20261106.zip';
      },
    )));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('export-logs')), 200);
    await tester.tap(find.byKey(const Key('export-logs')));
    await tester.pumpAndSettle();
    expect(shareCalls, hasLength(1));
    expect(find.byKey(const Key('share-logs')).hitTestable(), findsOneWidget);
    expect(find.byTooltip('再次分享日志'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('share-logs')));
    await tester.pumpAndSettle();
    expect(shareCalls, hasLength(2));
    expect(exports, 1);
  });

  testWidgets('share failure preserves the archive for retry without exporting again', (tester) async {
    shareResult = (_) async => throw PlatformException(code: 'share_failed');
    var exports = 0;
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(exportLogs: () async {
      exports++;
      return '/local/codepet-logs.zip';
    })));
    await tester.tap(find.byKey(const Key('export-logs')));
    await tester.pumpAndSettle();
    expect(find.textContaining('日志已导出，但无法打开系统分享'), findsOneWidget);
    expect(find.textContaining('日志导出失败'), findsNothing);
    shareResult = (_) async => 'com.tencent.mm';
    await tester.tap(find.byKey(const Key('share-logs')));
    await tester.pumpAndSettle();
    expect(shareCalls, hasLength(2));
    expect(exports, 1);
  });

  testWidgets('pending native share blocks duplicate export and share calls', (tester) async {
    final result = Completer<Object?>();
    shareResult = (_) => result.future;
    var exports = 0;
    await tester.pumpWidget(MaterialApp(home: AppSettingsScreen(exportLogs: () async {
      exports++;
      return '/local/codepet-logs.zip';
    })));
    await tester.tap(find.byKey(const Key('export-logs')));
    await tester.pump();
    expect(tester.widget<ListTile>(find.byKey(const Key('export-logs'))).onTap, isNull);
    expect(find.byKey(const Key('share-logs')), findsNothing);
    await tester.tap(find.byKey(const Key('export-logs')));
    expect(exports, 1);
    expect(shareCalls, hasLength(1));
    result.complete('dev.fluttercommunity.plus/share/dismissed');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('share-logs')), findsOneWidget);
  });
}
