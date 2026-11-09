import 'package:flutter/material.dart';

import '../layout/app_layout.dart';
import '../theme/app_semantics.dart';

/// Compact secondary action, with one shared icon, tint and hit area.
class AppRowMenu<T> extends StatelessWidget {
  const AppRowMenu({super.key, required this.itemBuilder, this.onSelected});
  final PopupMenuItemBuilder<T> itemBuilder;
  final PopupMenuItemSelected<T>? onSelected;
  @override
  Widget build(BuildContext context) => PopupMenuButton<T>(
    tooltip: '消息操作',
    padding: EdgeInsets.zero,
    style: IconButton.styleFrom(
      minimumSize: const Size(
        AppLayout.compactControlHeight,
        AppLayout.compactControlHeight,
      ),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    ),
    icon: Icon(
      Icons.keyboard_arrow_down,
      color: Theme.of(context).secondaryActionIcon,
    ),
    onSelected: onSelected,
    itemBuilder: itemBuilder,
  );
}
