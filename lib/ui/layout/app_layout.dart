import 'package:flutter/material.dart';

/// Shared dimensions. Text scaling remains controlled by the operating system.
abstract final class AppLayout {
  static const double compactRadius = 8;
  static const double radius = 12;
  static const double bubbleRadius = 16;
  static const double controlHeight = 44;
  static const double compactControlHeight = 32;
  static const double maxContentWidth = 960;
  static const double gap = 8;
  static const double sectionGap = 24;

  static double pageInset(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 16 : 24;

  static double cardGap(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return width < 600
        ? 8
        : width < 1000
        ? 12
        : 16;
  }
}
