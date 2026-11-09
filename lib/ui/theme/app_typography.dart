import 'package:flutter/material.dart';

/// Explicit type scale shared by all Material components and semantic roles.
/// Values are logical pixels; Flutter's system TextScaler remains untouched.
abstract final class AppTypography {
  static const pageTitle = 20.0;
  static const title = 16.0;
  static const body = 14.0;
  static const largeBody = 16.0;
  static const caption = 12.0;
  static const compactLabel = 11.0;

  static TextTheme apply(TextTheme base, Color muted) => base.copyWith(
    displayLarge: base.displayLarge?.copyWith(fontSize: 57),
    displayMedium: base.displayMedium?.copyWith(fontSize: 45),
    displaySmall: base.displaySmall?.copyWith(fontSize: 36),
    headlineLarge: base.headlineLarge?.copyWith(fontSize: 32),
    headlineMedium: base.headlineMedium?.copyWith(fontSize: 28),
    headlineSmall: base.headlineSmall?.copyWith(fontSize: 24),
    titleLarge: base.titleLarge?.copyWith(
      fontSize: pageTitle,
      fontWeight: FontWeight.w600,
    ),
    titleMedium: base.titleMedium?.copyWith(
      fontSize: title,
      fontWeight: FontWeight.w600,
    ),
    titleSmall: base.titleSmall?.copyWith(
      fontSize: body,
      fontWeight: FontWeight.w600,
    ),
    bodyLarge: base.bodyLarge?.copyWith(fontSize: largeBody, height: 1.45),
    bodyMedium: base.bodyMedium?.copyWith(fontSize: body, height: 1.4),
    bodySmall: base.bodySmall?.copyWith(
      fontSize: caption,
      height: 1.4,
      color: muted,
    ),
    labelLarge: base.labelLarge?.copyWith(fontSize: body),
    labelMedium: base.labelMedium?.copyWith(fontSize: caption),
    labelSmall: base.labelSmall?.copyWith(fontSize: compactLabel),
  );
}
