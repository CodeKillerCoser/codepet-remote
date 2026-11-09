import 'package:flutter/material.dart';

import '../layout/app_layout.dart';
import '../theme/app_semantics.dart';

/// Grouped content surface used by settings, summaries and transient panels.
class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppLayout.space12),
    this.color,
    this.border = false,
  });
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final bool border;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(AppLayout.radius),
        border: border
            ? Border.all(color: Theme.of(context).subtleBorder)
            : null,
      ),
      child: child,
    );
  }
}
