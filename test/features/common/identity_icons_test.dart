import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:codepet_remote/features/common/identity_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('accepts only absolute HTTPS provider icon URLs without credentials', () {
    expect(
      providerIconUri('https://cdn.example.com/provider/icon.png')?.toString(),
      'https://cdn.example.com/provider/icon.png',
    );
    expect(providerIconUri('http://cdn.example.com/icon.png'), isNull);
    expect(providerIconUri('//cdn.example.com/icon.png'), isNull);
    expect(providerIconUri('https:///icon.png'), isNull);
    expect(providerIconUri('https://user:secret@example.com/icon.png'), isNull);
    expect(providerIconUri('codex'), isNull);
  });

  testWidgets('renders an HTTPS provider icon as an image', (tester) async {
    final bytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAA'
      'C0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProviderIcon(
          icon: 'https://cdn.example.com/codex.png',
          providerIdentity: 'dev.codepet.codex',
          imageProvider: MemoryImage(bytes),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.byIcon(Icons.terminal), findsNothing);
  });

  testWidgets('delegates production HTTPS loading to the cache library',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ProviderIcon(
          icon: 'https://cdn.example.com/codex.png',
          providerIdentity: 'dev.codepet.codex',
        ),
      ),
    );

    expect(find.byType(CachedNetworkImage), findsOneWidget);
    expect(find.byIcon(Icons.terminal), findsOneWidget);
  });

  testWidgets('falls back when an HTTPS provider icon cannot be decoded',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ProviderIcon(
          icon: 'https://cdn.example.com/claude.png',
          providerIdentity: 'dev.codepet.claude',
          imageProvider: MemoryImage(Uint8List.fromList([0, 1, 2])),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
  });

  testWidgets('keeps legacy provider tokens as Material icon fallbacks',
      (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: ProviderIcon(
          icon: 'opencode',
          providerIdentity: 'dev.codepet.unknown',
        ),
      ),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.byIcon(Icons.code), findsOneWidget);
  });

  test('maps operating systems to recognizable platform icons', () {
    expect(operatingSystemIconData('Mac OS'), Icons.apple);
    expect(operatingSystemIconData('Windows 11'), Icons.window);
    expect(operatingSystemIconData('Android'), Icons.android);
    expect(operatingSystemIconData('iOS'), Icons.phone_iphone);
    expect(operatingSystemIconData('Linux'), Icons.terminal);
  });
}
