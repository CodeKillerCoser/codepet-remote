import 'package:codepet_remote/app/theme_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('theme preference defaults to system and persists explicit choices', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await ThemePreferences.load(), ThemeMode.system);
    for (final mode in ThemeMode.values) {
      await ThemePreferences.save(mode);
      expect(await ThemePreferences.load(), mode);
    }
    SharedPreferences.setMockInitialValues({ThemePreferences.key: 'unknown'});
    expect(await ThemePreferences.load(), ThemeMode.system);
  });
}
