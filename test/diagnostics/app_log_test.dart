import 'dart:io';

import 'package:codepet_remote/diagnostics/app_log.dart';
import 'package:codepet_remote/diagnostics/local_log_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('persists structured logs while redacting known secrets', () async {
    final temporaryDirectory = await Directory.systemTemp.createTemp(
      'codepet-app-log-test-',
    );
    addTearDown(() async {
      await AppLog.resetForTesting();
      if (await temporaryDirectory.exists()) {
        await temporaryDirectory.delete(recursive: true);
      }
    });
    final store = await LocalLogStore.open(
      rootDirectory: temporaryDirectory,
    );
    await AppLog.initialize(store: store);

    AppLog.named('test').warning(
      'request Bearer secret-token',
      error: StateError('{"credential":"private-value"}'),
    );
    await AppLog.flush();

    final contents = await File(
      '${store.logDirectory.path}/codepet.log',
    ).readAsString();
    expect(contents, contains('"logger":"test"'));
    expect(contents, contains('[REDACTED]'));
    expect(contents, isNot(contains('secret-token')));
    expect(contents, isNot(contains('private-value')));
  });
}
