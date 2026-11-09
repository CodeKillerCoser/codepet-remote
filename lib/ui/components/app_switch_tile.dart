import 'package:flutter/material.dart';

import '../layout/app_layout.dart';

/// Compact visual switch with the standard control hit area and a tappable row.
/// Colors and typography inherit SwitchTheme and ListTileTheme.
class AppSwitchTile extends StatelessWidget {
  const AppSwitchTile({
    super.key,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Widget title;
  final Widget? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: ListTile(
      title: title,
      subtitle: subtitle,
      enabled: onChanged != null,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      trailing: Transform.scale(
        scale: AppLayout.switchVisualScale,
        alignment: Alignment.centerRight,
        transformHitTests: false,
        child: Switch(value: value, onChanged: onChanged),
      ),
    ),
  );
}
