import 'package:flutter/material.dart';

import '../layout/app_layout.dart';
import '../theme/app_semantics.dart';

/// One settings group, with a shared ink surface and consistent row separators.
class AppSettingsSection extends StatelessWidget {
  const AppSettingsSection({
    super.key,
    required this.title,
    required this.children,
  });
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppLayout.sectionGap),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(context).bodyEmphasis.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppLayout.gap),
        Material(
          color: Theme.of(context).cardTheme.color,
          shape: Theme.of(context).cardTheme.shape,
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppLayout.space16,
                    ),
                    child: Divider(),
                  ),
                children[i],
              ],
            ],
          ),
        ),
      ],
    ),
  );
}
