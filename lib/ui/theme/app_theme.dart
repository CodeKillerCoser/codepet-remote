import 'package:flutter/material.dart';

import '../layout/app_layout.dart';
import 'app_semantics.dart';
import 'app_typography.dart';

/// One theme factory for all screens, overlays and system brightness modes.
abstract final class AppTheme {
  static final light = _build(Brightness.light);
  static final dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF008577),
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    final colors = scheme.copyWith(
      primary: dark ? const Color(0xFF62D9C7) : const Color(0xFF007F73),
      onPrimary: dark ? const Color(0xFF003C35) : Colors.white,
      surface: dark ? const Color(0xFF111B1A) : Colors.white,
      surfaceContainerLow: dark
          ? const Color(0xFF192725)
          : const Color(0xFFF3F8F7),
      surfaceContainer: dark
          ? const Color(0xFF20302D)
          : const Color(0xFFEDF5F3),
      surfaceContainerHigh: dark
          ? const Color(0xFF283936)
          : const Color(0xFFE7F1EE),
      surfaceContainerHighest: dark
          ? const Color(0xFF31433F)
          : const Color(0xFFDFECE8),
      primaryContainer: dark
          ? const Color(0xFF07564B)
          : const Color(0xFFD5F5ED),
      onPrimaryContainer: dark
          ? const Color(0xFFC0F7E8)
          : const Color(0xFF124D42),
      secondary: dark ? const Color(0xFF89D5C7) : const Color(0xFF267C6F),
      onSecondary: dark ? const Color(0xFF00382F) : Colors.white,
      secondaryContainer: dark
          ? const Color(0xFF214D43)
          : const Color(0xFFDCF3EA),
      onSecondaryContainer: dark
          ? const Color(0xFFCAF5E7)
          : const Color(0xFF185548),
      onSurface: dark ? const Color(0xFFE6F0ED) : const Color(0xFF192A26),
      onSurfaceVariant: dark
          ? const Color(0xFFAFCCC3)
          : const Color(0xFF536B63),
      outline: dark ? const Color(0xFF6D8E83) : const Color(0xFF819E93),
      outlineVariant: dark ? const Color(0xFF354F45) : const Color(0xFFD8E7E1),
    );
    final base = ThemeData(useMaterial3: true, colorScheme: colors);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppLayout.radius),
    );
    final text = AppTypography.apply(base.textTheme, colors.onSurfaceVariant);
    return base.copyWith(
      textTheme: text,
      primaryTextTheme: AppTypography.apply(base.primaryTextTheme, colors.onPrimary),
      extensions: [AppSemantics.forBrightness(brightness)],
      scaffoldBackgroundColor: colors.surface,
      drawerTheme: DrawerThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: const RoundedRectangleBorder(),
        width: AppLayout.drawerMaxWidth,
      ),
      iconTheme: IconThemeData(
        color: colors.onSurfaceVariant,
        size: AppLayout.iconSize,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: colors.onSurfaceVariant, size: AppLayout.iconSize),
      ),
      cardTheme: CardThemeData(
        color: colors.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape,
      ),
      dividerTheme: DividerThemeData(
        color: colors.outlineVariant.withValues(alpha: .5),
        thickness: .5,
        space: 1,
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minTileHeight: 52,
        horizontalTitleGap: 12,
        iconColor: colors.onSurfaceVariant,
        selectedColor: colors.onSecondaryContainer,
        selectedTileColor: colors.secondaryContainer,
        titleTextStyle: text.bodyLarge,
        subtitleTextStyle: text.bodySmall,
        shape: shape,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppLayout.radius),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppLayout.radius),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppLayout.radius),
          borderSide: BorderSide(color: colors.primary),
        ),
        hintStyle: text.bodyLarge?.copyWith(color: colors.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          textStyle: text.labelLarge,
          minimumSize: const Size(0, AppLayout.controlHeight),
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          textStyle: text.labelLarge,
          minimumSize: const Size(0, AppLayout.controlHeight),
          shape: shape,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: text.labelLarge,
          minimumSize: const Size(0, AppLayout.controlHeight),
          shape: shape,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: colors.onSurfaceVariant,
          minimumSize: const Size(44, 44),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        elevation: 3,
        shape: shape,
        textStyle: text.bodyMedium,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        labelStyle: text.labelLarge,
        shape: shape,
        side: BorderSide.none,
        backgroundColor: colors.surfaceContainerLow,
        selectedColor: colors.secondaryContainer,
      ),
    );
  }
}
