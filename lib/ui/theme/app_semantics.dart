import 'package:flutter/material.dart';

/// App-specific roles beyond Material's ColorScheme. Kept in ThemeData so
/// brightness changes and animated theme transitions update every consumer.
@immutable
class AppSemantics extends ThemeExtension<AppSemantics> {
  const AppSemantics({
    required this.success,
    required this.warning,
    required this.unread,
  });
  final Color success, warning, unread;

  factory AppSemantics.forBrightness(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return AppSemantics(
      success: dark ? const Color(0xFF81D99B) : const Color(0xFF237A42),
      warning: dark ? const Color(0xFFFFC66D) : const Color(0xFF925700),
      unread: dark ? const Color(0xFF94C8FF) : const Color(0xFF1769AA),
    );
  }

  @override
  AppSemantics copyWith({Color? success, Color? warning, Color? unread}) =>
      AppSemantics(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        unread: unread ?? this.unread,
      );

  @override
  AppSemantics lerp(covariant AppSemantics? other, double t) => other == null
      ? this
      : AppSemantics(
          success: Color.lerp(success, other.success, t)!,
          warning: Color.lerp(warning, other.warning, t)!,
          unread: Color.lerp(unread, other.unread, t)!,
        );
}

extension AppThemeRoles on ThemeData {
  AppSemantics get semantics =>
      extension<AppSemantics>() ?? AppSemantics.forBrightness(brightness);
  Color get errorSurface => Color.alphaBlend(
    colorScheme.error.withValues(alpha: .06),
    colorScheme.surface,
  );
  Color get approvalSurface => Color.alphaBlend(
    semantics.warning.withValues(alpha: .10),
    colorScheme.surface,
  );
  Color get subtleBorder => colorScheme.outlineVariant.withValues(alpha: .5);
  Color get secondaryActionIcon => colorScheme.onSurfaceVariant.withValues(alpha: .45);
  Color get selectedOutline => colorScheme.primary.withValues(alpha: .35);
  Color get overlayShadow => colorScheme.shadow.withValues(alpha: .18);
  Color get overlayOutline => colorScheme.outlineVariant.withValues(alpha: .7);
  TextStyle get statusLabel =>
      textTheme.labelMedium!.copyWith(fontWeight: FontWeight.w600);
  TextStyle get trafficLabel =>
      textTheme.labelSmall!.copyWith(fontWeight: FontWeight.w600);
  TextStyle get trafficBody =>
      textTheme.bodySmall!.copyWith(fontWeight: FontWeight.w600);
  TextStyle get bodyEmphasis =>
      textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w600);
  TextStyle get bodyStrong =>
      textTheme.bodyMedium!.copyWith(fontWeight: FontWeight.w700);
  TextStyle get titleStrong =>
      textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w700);
  TextStyle get titleRegular =>
      textTheme.titleMedium!.copyWith(fontWeight: FontWeight.w400);
  TextStyle get labelStrong =>
      textTheme.labelLarge!.copyWith(fontWeight: FontWeight.w700);
  TextStyle get codeText =>
      textTheme.bodyMedium!.copyWith(fontFamily: 'monospace');
  TextStyle get toastText =>
      textTheme.bodyMedium!.copyWith(decoration: TextDecoration.none);
  TextStyle get errorText =>
      textTheme.bodyMedium!.copyWith(color: colorScheme.error);
  TextStyle get mutedText =>
      textTheme.bodyMedium!.copyWith(color: colorScheme.onSurfaceVariant);
}

/// Shared rendering strengths, separate from layout dimensions.
abstract final class AppEffects {
  static const toastShadowOpacity = .18;
  static const toastSurfaceOpacity = .07;
  static const toastBorderOpacity = .28;
}
