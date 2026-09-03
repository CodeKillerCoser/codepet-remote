import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Core is independent of application, UI, and infrastructure', () {
    _expectNoImports(
      Directory('lib/core'),
      const [
        '/application/',
        '/devices/',
        '/discovery/',
        '/features/',
        '/gateway/',
        '../../pairing/',
        'package:codepet_remote/pairing/',
        '/security/',
        'dart:io',
        'package:flutter',
        'package:codepet_',
      ],
    );
  });

  test('Application depends only on Core and application-owned ports', () {
    _expectNoImports(
      Directory('lib/application'),
      const [
        '/app/',
        '/devices/',
        '/discovery/',
        '/features/',
        '/gateway/',
        '../../pairing/',
        'package:codepet_remote/pairing/',
        '/security/',
        'dart:io',
        'package:flutter',
        'package:codepet_',
      ],
    );
  });

  test('Presentation does not reach through application ports to adapters', () {
    _expectNoImports(
      Directory('lib/features'),
      const [
        '/admission/',
        '/channel/',
        '/devices/',
        '/discovery/',
        '/gateway/',
        '../../pairing/',
        'package:codepet_remote/pairing/',
        '/security/',
        '/application/ports/gateway_client.dart',
        'package:codepet_',
      ],
    );
  });

  test('generated packages share one compatible Core schema surface', () {
    final gatewayCore = File(
      'sdk/gateway/codepet-core-sdk/lib/src/generated.dart',
    ).readAsStringSync();
    final lanCore = File(
      'sdk/lan/codepet-core-sdk/lib/src/generated.dart',
    ).readAsStringSync();
    final schemaVersionDeclaration = RegExp(
      r'const int coreSchemaVersion = \d+;\s*',
    );

    expect(
      gatewayCore.replaceAll(schemaVersionDeclaration, ''),
      lanCore.replaceAll(schemaVersionDeclaration, ''),
      reason: 'Gateway and LAN generated Core types must not drift',
    );
    expect(
      File('pubspec.yaml').readAsStringSync(),
      contains('path: sdk/gateway/codepet-core-sdk'),
      reason: 'The app must resolve one canonical codepet_core_sdk package',
    );
  });
}

void _expectNoImports(Directory root, List<String> forbiddenSegments) {
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final imports = entity
        .readAsLinesSync()
        .where((line) =>
            line.trimLeft().startsWith('import ') ||
            line.trimLeft().startsWith('export '))
        .join('\n');
    for (final segment in forbiddenSegments) {
      expect(
        imports.contains(segment),
        isFalse,
        reason: '${entity.path} must not depend on $segment',
      );
    }
  }
}
