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
      elevation: 3,
      shadowColor: colors.shadow.withValues(alpha: 0.18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}
