import '../../ui/theme/app_semantics.dart';
import '../../ui/layout/app_layout.dart';
import 'package:flutter/material.dart';

/// A compact, opaque disclosure surface shared by detail popovers.
class FloatingDetailPanel extends StatelessWidget {
  const FloatingDetailPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surfaceContainerLow.withAlpha(255),
      surfaceTintColor: Colors.transparent,
      elevation: AppLayout.overlayElevation,
      shadowColor: Theme.of(context).overlayShadow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppLayout.radius),
        side: BorderSide(color: Theme.of(context).overlayOutline),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
