import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';

/// Shared page frame; pages own content and actions, not viewport policies.
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.appBar,
    this.drawer,
    this.bottomBarBorder = true,
    required this.body,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.resizeToAvoidBottomInset = true,
    this.constrainContent = true,
  });
  final PreferredSizeWidget? appBar;
  final Widget? drawer;
  final bool bottomBarBorder;
  final Widget body;
  final Widget? bottomNavigationBar, floatingActionButton;
  final bool resizeToAvoidBottomInset, constrainContent;

  Widget _content(Widget child) => constrainContent
      ? Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppLayout.maxContentWidth,
            ),
            child: SizedBox(width: double.infinity, child: child),
          ),
        )
      : child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
          ),
      child: Scaffold(
        appBar: appBar,
        drawer: drawer,
        // Leave a usable swipe area inside Android’s system back-gesture edge.
        drawerEdgeDragWidth: 72,
        body: _content(body),
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        bottomNavigationBar: bottomNavigationBar == null
            ? null
            : bottomBarBorder
            ? _BottomBar(child: _content(bottomNavigationBar!))
            : _content(bottomNavigationBar!),
        floatingActionButton: floatingActionButton,
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surface,
      border: Border(
        top: BorderSide(color: Theme.of(context).dividerColor, width: .5),
      ),
    ),
    child: child,
  );
}
