import 'package:flutter/material.dart';
import '../../ui/theme/app_semantics.dart';
import '../../ui/layout/app_layout.dart';
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
            outerPadding: EdgeInsets.only(top: mediaQuery.padding.top + AppLayout.space12),
            innerPadding: const EdgeInsets.symmetric(vertical: AppLayout.space4),
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
    final accent = _accentColor(type, Theme.of(context));
    return Semantics(
      container: true,
      liveRegion: true,
      child: Material(
        key: const Key('app-toast-card'),
        elevation: AppLayout.toastElevation,
        shadowColor: colors.shadow.withValues(alpha: AppEffects.toastShadowOpacity),
        color: Color.alphaBlend(
          accent.withValues(alpha: AppEffects.toastSurfaceOpacity),
          colors.surface,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppLayout.radius),
          side: BorderSide(color: accent.withValues(alpha: AppEffects.toastBorderOpacity)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppLayout.space12, vertical: AppLayout.space10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_icon(type), size: 20, color: accent),
              const SizedBox(width: AppLayout.space9),
              Flexible(
                child: Text.rich(
                  content,
                  key: const Key('app-toast-content'),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).toastText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _accentColor(AppToastType type, ThemeData theme) =>
      switch (type) {
        AppToastType.info => theme.colorScheme.primary,
        AppToastType.success => theme.semantics.success,
        AppToastType.warning => theme.semantics.warning,
        AppToastType.error => theme.colorScheme.error,
      };

  static IconData _icon(AppToastType type) => switch (type) {
        AppToastType.info => Icons.info_outline_rounded,
        AppToastType.success => Icons.check_circle_outline_rounded,
        AppToastType.warning => Icons.warning_amber_rounded,
        AppToastType.error => Icons.error_outline_rounded,
      };
}
