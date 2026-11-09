import 'package:codepet_remote/features/settings/app_settings_screen.dart';
import 'package:codepet_remote/core/domain/notification.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'theme selection saves immediately and failed save retains value',
    (tester) async {
      ThemeMode? saved;
      var fail = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: AppSettingsScreen(
            exportLogs: () async => '',
            onThemeModeChanged: (mode) async {
              if (fail) throw StateError('save');
              saved = mode;
            },
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('theme-mode-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('theme-option-dark')));
      await tester.pumpAndSettle();
      expect(saved, ThemeMode.dark);
      expect(find.text('深色'), findsOneWidget);
      fail = true;
      await tester.tap(find.byKey(const Key('theme-mode-selector')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('theme-option-light')));
      await tester.pumpAndSettle();
      expect(find.text('深色'), findsOneWidget);
      expect(find.text('主题设置保存失败，请重试'), findsOneWidget);
    },
  );

  testWidgets(
    'signaling edit is a separate route and updates summary on return',
    (tester) async {
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: AppSettingsScreen(
            exportLogs: () async => '',
            onSignalingServiceChanged: (value) async => saved = value,
          ),
        ),
      );
      expect(find.byKey(const Key('signaling-service-address')), findsNothing);
      expect(find.textContaining('当前通道'), findsNothing);
      await tester.ensureVisible(
        find.byKey(const Key('signaling-service-entry')),
      );
      await tester.tap(find.byKey(const Key('signaling-service-entry')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('signaling-service-address')),
        'relay.example.com',
      );
      await tester.tap(find.byKey(const Key('save-signaling-service')));
      await tester.pumpAndSettle();
      expect(saved, 'https://relay.example.com:8443');
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text(saved!), findsOneWidget);
      await tester.tap(find.byKey(const Key('signaling-service-entry')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('signaling-service-address')),
            )
            .controller!
            .text,
        saved,
      );
    },
  );

  for (final theme in [AppTheme.light, AppTheme.dark]) {
    testWidgets(
      'grouped settings stay usable at 2x text in ${theme.brightness.name}',
      (tester) async {
        tester.view.physicalSize = const Size(320, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: AppSettingsScreen(
              exportLogs: () async => '',
              notificationPreferences: const NotificationPreferences(),
              notificationsAllowed: () async => false,
              onNotificationsChanged: (value) async => value,
              onSignalingServiceChanged: (_) async {},
              onThemeModeChanged: (_) async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.byKey(const Key('export-logs')),
          200,
        );
        expect(
          find.byKey(const Key('export-logs')).hitTestable(),
          findsOneWidget,
        );
        expect(find.textContaining('当前通道'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
