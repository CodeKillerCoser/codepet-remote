import 'package:flutter/material.dart';
import 'package:sonner_toast/sonner_toast.dart';

enum AppToastType { info, success, warning, error }

class AppToastHost extends StatelessWidget {
  const AppToastHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final stackWidth =
        (mediaQuery.size.width - 48).clamp(0.0, 300.0).toDouble();
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        SonnerOverlay(
          key: Sonner.overlayKey,
          config: SonnerConfig(
            alignment: Alignment.topCenter,
            variant: SonnerVariant.top,
            width: stackWidth,
            outerPadding: EdgeInsets.only(top: mediaQuery.padding.top + 12),
            innerPadding: const EdgeInsets.symmetric(vertical: 4),
            collapsedOffset: 10,
            expandedSpacing: 8,
            maxVisibleToasts: 3,
          ),
        ),
      ],
    );
  }
}

abstract final class AppToast {
  static void show({
    required TextSpan content,
    AppToastType type = AppToastType.info,
    Duration duration = const Duration(seconds: 3),
  }) {
    Sonner.toast(
      duration: duration,
      builder: (context, dismissToast) => _AppToastCard(
        type: type,
        content: content,
      ),
    );
  }
}

class _AppToastCard extends StatelessWidget {
  const _AppToastCard({required this.type, required this.content});

  final AppToastType type;
  final TextSpan content;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final accent = _accentColor(type, colors);
    final foreground = colors.onSurface;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        key: const Key('app-toast-card'),
        elevation: 5,
        shadowColor: colors.shadow.withValues(alpha: 0.18),
        color: Color.alphaBlend(
          accent.withValues(alpha: 0.07),
          colors.surface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: accent.withValues(alpha: 0.28)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon(type), size: 20, color: accent),
              const SizedBox(width: 9),
              Flexible(
                child: Text.rich(
                  content,
                  key: const Key('app-toast-content'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: foreground,
                    fontSize: 14,
                    height: 1.25,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _accentColor(AppToastType type, ColorScheme colors) =>
      switch (type) {
        AppToastType.info => colors.primary,
        AppToastType.success => const Color(0xFF238636),
        AppToastType.warning => const Color(0xFFB26A00),
        AppToastType.error => colors.error,
      };

  static IconData _icon(AppToastType type) => switch (type) {
        AppToastType.info => Icons.info_outline_rounded,
        AppToastType.success => Icons.check_circle_outline_rounded,
        AppToastType.warning => Icons.warning_amber_rounded,
        AppToastType.error => Icons.error_outline_rounded,
      };
}
