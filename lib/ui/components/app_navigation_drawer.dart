import 'package:flutter/material.dart';

import '../layout/app_layout.dart';

/// Navigation shell; visual styles come from DrawerTheme and ListTileTheme.
class AppNavigationDrawer extends StatelessWidget {
  const AppNavigationDrawer({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    required this.footer,
  });

  final String title, subtitle;
  final List<Widget> children;
  final Widget footer;

  @override
  Widget build(BuildContext context) {
    final inset = AppLayout.pageInset(context);
    final text = Theme.of(context).textTheme;
    return Drawer(
      width: AppLayout.drawerWidth(context),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: EdgeInsets.all(inset),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleLarge),
                  const SizedBox(height: AppLayout.compactGap),
                  Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(horizontal: AppLayout.gap),
                // ListTile ink must share the scrollable's transform/clip.
                // Painting on Drawer's Material leaves selection behind during
                // Android's stretch overscroll.
                children: [
                  for (final child in children)
                    Material(type: MaterialType.transparency, child: child),
                ],
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: inset),
              child: const Divider(),
            ),
            Padding(
              padding: const EdgeInsets.all(AppLayout.gap),
              child: footer,
            ),
          ],
        ),
      ),
    );
  }
}
