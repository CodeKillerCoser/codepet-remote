import 'dart:io';

import 'package:codepet_remote/features/conversations/widgets/conversation_list_item.dart';
import 'package:codepet_remote/ui/theme/app_semantics.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('status indicators maintain contrast on light and dark surfaces', () {
    for (final theme in [AppTheme.light, AppTheme.dark]) {
      final roles = theme.semantics;
      for (final foreground in [roles.success, roles.warning, roles.unread]) {
        for (final background in [
          theme.colorScheme.surface,
          theme.colorScheme.surfaceContainerLow,
        ]) {
          final a = foreground.computeLuminance();
          final b = background.computeLuminance();
          final contrast = a > b
              ? (a + .05) / (b + .05)
              : (b + .05) / (a + .05);
          expect(contrast, greaterThanOrEqualTo(3));
        }
      }
    }
  });

  testWidgets('existing unread indicator follows a replaced theme role', (
    tester,
  ) async {
    for (final base in [AppTheme.light, AppTheme.dark]) {
      final theme = base.copyWith(
        extensions: [base.semantics.copyWith(unread: const Color(0xFFFF00FF))],
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: ConversationIndicators(running: false, unread: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dot = tester.widget<Container>(
        find.descendant(
          of: find.byType(ConversationIndicators),
          matching: find.byType(Container),
        ),
      );
      expect((dot.decoration! as BoxDecoration).color, const Color(0xFFFF00FF));
    }
  });

  test('feature widgets do not reintroduce literal palette or typography', () {
    final inlineStyle = RegExp(
      r'Color\(0x|Colors\.(?!transparent\b)\w+|\bfontSize\s*:|\bfontWeight\s*:|\bfontFamily\s*:',
    );
    final violations = <String>[];
    for (final file in Directory(
      'lib/features',
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      if (inlineStyle.hasMatch(file.readAsStringSync())) {
        violations.add(file.path);
      }
    }
    expect(
      violations,
      isEmpty,
      reason: 'Use shared theme roles rather than per-page styles.',
    );
  });
}
