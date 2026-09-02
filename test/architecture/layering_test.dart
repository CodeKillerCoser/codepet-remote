import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Core and Application keep inward dependency direction', () {
    _expectNoImports(
      Directory('lib/core'),
      const ['/gateway/', '/discovery/', '/features/', '/application/'],
    );
    _expectNoImports(
      Directory('lib/application'),
      const ['/gateway/', '/discovery/', '/features/'],
    );
  });
}

void _expectNoImports(Directory root, List<String> forbiddenSegments) {
  for (final entity in root.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final source = entity.readAsStringSync();
    for (final segment in forbiddenSegments) {
      expect(
        source.contains(segment),
        isFalse,
        reason: '${entity.path} must not depend on $segment',
      );
    }
  }
}
