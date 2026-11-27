import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'app_typography.dart';

/// Adapt the shared type scale to the terminal library's cell-based renderer.
/// ANSI colors continue to come from the terminal palette, preserving programs.
abstract final class AppTerminalTheme {
  static TerminalStyle textStyle(BuildContext context) => TerminalStyle(
    fontSize:
        Theme.of(context).textTheme.bodySmall?.fontSize ??
        AppTypography.caption,
  );
}
