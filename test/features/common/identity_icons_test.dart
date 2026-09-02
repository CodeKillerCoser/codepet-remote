import 'package:codepet_remote/features/common/identity_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maps operating systems to recognizable platform icons', () {
    expect(operatingSystemIconData('Mac OS'), Icons.apple);
    expect(operatingSystemIconData('Windows 11'), Icons.window);
    expect(operatingSystemIconData('Android'), Icons.android);
    expect(operatingSystemIconData('iOS'), Icons.phone_iphone);
    expect(operatingSystemIconData('Linux'), Icons.terminal);
  });
}
