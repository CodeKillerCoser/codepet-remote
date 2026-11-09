import 'package:flutter/material.dart';

/// Shared dimensions. Text scaling remains controlled by the operating system.
abstract final class AppLayout {

  // Shared spacing scale; specialized business layouts compose these values.
  static const double space2 = 2;
  static const double space4 = 4;
  static const double space6 = 6;
  static const double space8 = 8;
  static const double space9 = 9;
  static const double space10 = 10;
  static const double space12 = 12;
  static const double space14 = 14;
  static const double space16 = 16;
  static const double space20 = 20;
  static const double space24 = 24;
  static const double space28 = 28;
  static const double space32 = 32;
  static const double space48 = 48;
  static const double subtleRadius = 6;
  static const double bubbleTailRadius = 5;
  static const double pillRadius = 24;
  static const double overlayElevation = 3;
  static const double toastElevation = 5;

  static const double compactRadius = 8;
  static const double radius = 12;
  static const double bubbleRadius = 16;
  static const double controlHeight = 44;
  static const double compactControlHeight = 32;
  static const double maxContentWidth = 960;
  static const double gap = 8;
  static const double compactGap = 4;
  static const double iconSize = 22;
  static const double drawerMaxWidth = 360;
  static const double drawerWidthFraction = .84;

  static double drawerWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * drawerWidthFraction)
          .clamp(0.0, drawerMaxWidth);
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
