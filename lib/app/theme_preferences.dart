import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class ThemePreferences {
  static const key = 'appearance_theme_mode_v1';
  static Future<ThemeMode> load() async {
    final value = (await SharedPreferences.getInstance()).getString(key);
    final mode =
        ThemeMode.values.where((mode) => mode.name == value).firstOrNull ??
        ThemeMode.system;
    await _syncNative(mode);
    return mode;
  }

  static Future<void> save(ThemeMode mode) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key,
      mode.name,
    )) {
      throw StateError('Unable to save theme mode');
    }
    await _syncNative(mode);
  }

  static Future<void> _syncNative(ThemeMode mode) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await const MethodChannel('com.codepet.remote/appearance')
          .invokeMethod<void>('setThemeMode', mode.name);
    } on MissingPluginException {
      // Widget tests and platforms without the native appearance bridge.
    }
  }
}
