import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../layout/app_layout.dart';
import 'app_semantics.dart';

/// Shared rich-message typography, code and quote surfaces.
abstract final class AppMarkdownTheme {
  static MarkdownStyleSheet style(ThemeData theme, TextStyle body) {
    final colors = theme.colorScheme;
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: body,
      pPadding: EdgeInsets.zero,
      blockSpacing: 10,
      listBullet: body,
      code: theme.codeText.copyWith(
        backgroundColor: colors.surfaceContainerHighest,
      ),
      codeblockPadding: const EdgeInsets.all(AppLayout.space12),
      codeblockDecoration: BoxDecoration(
        color: colors.surfaceContainer,
        borderRadius: BorderRadius.circular(AppLayout.radius),
        border: Border.all(color: colors.outlineVariant),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(
        AppLayout.space12,
        AppLayout.space8,
        AppLayout.space10,
        AppLayout.space8,
      ),
      blockquoteDecoration: BoxDecoration(
        color: colors.surfaceContainer,
        border: Border(left: BorderSide(color: colors.primary, width: 3)),
      ),
      tableBorder: TableBorder.all(color: colors.outlineVariant),
    );
  }
}
