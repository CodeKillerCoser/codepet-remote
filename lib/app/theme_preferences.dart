import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract final class ThemePreferences {
  static const key = 'appearance_theme_mode_v1';
  static Future<ThemeMode> load() async {
    final value = (await SharedPreferences.getInstance()).getString(key);
    return ThemeMode.values.where((mode) => mode.name == value).firstOrNull ?? ThemeMode.system;
  }
  static Future<void> save(ThemeMode mode) async {
    if (!await (await SharedPreferences.getInstance()).setString(key, mode.name)) {
      throw StateError('Unable to save theme mode');
    }
  }
}
