import 'dart:io';

import 'package:codepet_remote/app/theme_preferences.dart';
import 'package:codepet_remote/ui/theme/app_markdown_theme.dart';
import 'package:codepet_remote/ui/theme/app_semantics.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('native day/night surfaces match Flutter launch and normal windows', () {
    for (final entry in {
      'values': AppTheme.light,
      'values-night': AppTheme.dark,
    }.entries) {
      final source = File('android/app/src/main/res/${entry.key}/colors.xml')
          .readAsStringSync();
      final hex = RegExp(r'<color name="app_surface">#([0-9A-Fa-f]{6})</color>')
          .firstMatch(source)!
          .group(1)!;
      expect(
        Color(0xFF000000 | int.parse(hex, radix: 16)),
        entry.value.colorScheme.surface,
      );
      final splash = File(
        'android/app/src/main/res/${entry.key}-v31/styles.xml',
      ).readAsStringSync();
      expect(
        splash,
        contains(
          'name="android:windowSplashScreenBackground">@color/app_surface',
        ),
      );
      final normal = File('android/app/src/main/res/${entry.key}/styles.xml')
          .readAsStringSync();
      expect(
        normal,
        contains('name="android:windowBackground">@color/app_surface'),
      );
    }
  });

  test(
    'code, menus and input text use the shared type scale in both themes',
    () {
      for (final theme in [AppTheme.light, AppTheme.dark]) {
        expect(theme.appBarTheme.titleTextStyle!.fontSize, 20);
        expect(theme.listTileTheme.titleTextStyle!.fontSize, 16);
        expect(theme.listTileTheme.subtitleTextStyle!.fontSize, 12);
        expect(theme.popupMenuTheme.textStyle!.fontSize, 14);
        expect(theme.inputDecorationTheme.hintStyle!.fontSize, 16);
        for (final body in [
          theme.textTheme.bodyMedium!,
          theme.textTheme.bodyLarge!,
        ]) {
          final markdown = AppMarkdownTheme.style(theme, body);
          expect(markdown.code!.fontSize, theme.codeText.fontSize);
          expect(markdown.code!.fontFamily, theme.codeText.fontFamily);
          expect(markdown.p, body);
        }
      }
    },
  );

  test(
    'theme preference syncs native splash mode on save and restore',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      const channel = MethodChannel('com.codepet.remote/appearance');
      final calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'setThemeMode');
            calls.add(call.arguments as String);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      SharedPreferences.setMockInitialValues({});
      for (final mode in [ThemeMode.dark, ThemeMode.light, ThemeMode.system]) {
        await ThemePreferences.save(mode);
        expect(await ThemePreferences.load(), mode);
      }
      expect(calls, ['dark', 'dark', 'light', 'light', 'system', 'system']);
    },
  );
}
