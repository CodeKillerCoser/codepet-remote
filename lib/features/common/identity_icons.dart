import 'package:flutter/material.dart';

IconData providerIconData(String value) {
  final normalized = value.toLowerCase();
  if (normalized.contains('codex')) return Icons.terminal;
  if (normalized.contains('claude')) return Icons.auto_awesome_outlined;
  if (normalized.contains('opencode')) return Icons.code;
  return Icons.extension_outlined;
}

IconData operatingSystemIconData(String value) {
  final normalized = value.toLowerCase();
  if (normalized.contains('mac') || normalized.contains('darwin')) {
    return Icons.apple;
  }
  if (normalized.contains('windows')) return Icons.window;
  if (normalized.contains('android')) return Icons.android;
  if (normalized.contains('ios') ||
      normalized.contains('iphone') ||
      normalized.contains('ipad')) {
    return Icons.phone_iphone;
  }
  if (normalized.contains('linux')) return Icons.terminal;
  return Icons.computer_outlined;
}
