import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:codepet_remote/diagnostics/local_log_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'codepet-log-test-',
    );
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('rotates logs by size and keeps the configured shard count', () async {
    final store = await LocalLogStore.open(
      rootDirectory: temporaryDirectory,
      maxFileBytes: 40,
      maxFileCount: 3,
    );

    await store.writeLine('a' * 30);
    await store.writeLine('b' * 30);
    await store.writeLine('c' * 30);
    await store.writeLine('d' * 30);

    final files = await store.logDirectory
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    expect(files, hasLength(3));
    expect(
      await File('${store.logDirectory.path}/codepet.log').readAsString(),
      contains('d' * 30),
    );
    expect(
      await File('${store.logDirectory.path}/codepet.1.log').readAsString(),
      contains('c' * 30),
    );
    expect(
      await File('${store.logDirectory.path}/codepet.2.log').readAsString(),
      contains('b' * 30),
    );
  });

  test('removes log shards older than the retention period', () async {
    final logDirectory = Directory('${temporaryDirectory.path}/logs');
    await logDirectory.create(recursive: true);
    final expired = File('${logDirectory.path}/codepet.1.log');
    await expired.writeAsString('expired');
    await expired.setLastModified(DateTime.now().subtract(
      const Duration(days: 8),
    ));

    await LocalLogStore.open(rootDirectory: temporaryDirectory);

    expect(await expired.exists(), isFalse);
  });

  test('exports all retained shards and metadata as a zip archive', () async {
    final store = await LocalLogStore.open(
      rootDirectory: temporaryDirectory,
      maxFileBytes: 40,
      maxFileCount: 3,
    );
    await store.writeLine('first diagnostic event');
    await store.writeLine('second diagnostic event that rotates');

    final exportPath = await store.exportZip();
    final exported = File(exportPath);
    final archive = ZipDecoder().decodeBytes(await exported.readAsBytes());
    final names = archive.files.map((file) => file.name).toSet();

    expect(await exported.exists(), isTrue);
    expect(names, containsAll(['codepet.log', 'codepet.1.log', 'README.txt']));
    final readme = archive.files.singleWhere(
      (file) => file.name == 'README.txt',
    );
    expect(utf8.decode(readme.content), contains('Retention: 7 days'));
  });
}
