import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';

import 'log_line.dart';

class LocalLogStore {
  LocalLogStore._({
    required this.rootDirectory,
    required this.maxFileBytes,
    required this.maxFileCount,
    required this.retention,
  });

  static const int defaultMaxFileBytes = 2 * 1024 * 1024;
  static const int defaultMaxFileCount = 5;
  static const Duration defaultRetention = Duration(days: 7);

  final Directory rootDirectory;
  final int maxFileBytes;
  final int maxFileCount;
  final Duration retention;
  Future<void> _pending = Future<void>.value();
  DateTime _nextRetentionCheck = DateTime.fromMillisecondsSinceEpoch(0);

  Directory get logDirectory =>
      Directory('${rootDirectory.path}${Platform.pathSeparator}logs');

  Directory get exportDirectory =>
      Directory('${rootDirectory.path}${Platform.pathSeparator}exports');

  File get _activeFile =>
      File('${logDirectory.path}${Platform.pathSeparator}codepet.log');

  static Future<LocalLogStore> open({
    Directory? rootDirectory,
    int maxFileBytes = defaultMaxFileBytes,
    int maxFileCount = defaultMaxFileCount,
    Duration retention = defaultRetention,
  }) async {
    if (maxFileBytes <= 0) {
      throw ArgumentError.value(maxFileBytes, 'maxFileBytes');
    }
    if (maxFileCount <= 0) {
      throw ArgumentError.value(maxFileCount, 'maxFileCount');
    }
    final root =
        rootDirectory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}diagnostics',
        );
    final store = LocalLogStore._(
      rootDirectory: root,
      maxFileBytes: maxFileBytes,
      maxFileCount: maxFileCount,
      retention: retention,
    );
    await store.logDirectory.create(recursive: true);
    await store.exportDirectory.create(recursive: true);
    await store._pruneExpired();
    await store._convertLegacyLogs();
    return store;
  }

  Future<void> writeRecord(Map<String, dynamic> record) {
    final line = formatLogLine(record);
    final bytes = utf8.encode('$line\n');
    final operation = _pending.then((_) async {
      if (DateTime.now().isAfter(_nextRetentionCheck)) {
        await _pruneExpired();
      }
      await _rotateIfNeeded(bytes.length);
      await _activeFile.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    });
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> flush() => _pending;

  Future<String> exportZip() async {
    // Snapshot on the writer queue: rotation cannot rename a shard while it is read.
    final snapshot = _pending.then((_) async {
      await _pruneExpired();
      return {
        for (final file in await _logFiles())
          file.uri.pathSegments.last: await file.readAsBytes(),
      };
    });
    _pending = snapshot.then<void>((_) {}).catchError((Object _) {});
    final files = await snapshot;
    final archive = Archive();
    for (final file in files.entries) {
      archive.addFile(ArchiveFile.bytes(file.key, file.value));
    }
    archive.addFile(
      ArchiveFile.string(
        'README.txt',
        'CodePet Remote diagnostic logs\n'
            'codepet.log 为当前日志，codepet.N.log 为轮转历史（N 越大越旧）。\n'
            '格式：年月日 时分秒.毫秒+时区 pid thread 级别 文件:行号 [模块] 内容。\n'
            'thread 为产生日志的系统线程 ID；isolate 单独记录；缺失字段用 -。\n'
            '仅存储和导出文本日志；旧日志缺失的字段无法补回。\n'
            '时间均为 UTC；北京时间加 8 小时。\n'
            'Created: ${DateTime.now().toUtc().toIso8601String()}\n'
            'Retention: ${retention.inDays} days\n'
            'Maximum files: $maxFileCount\n'
            'Maximum file size: $maxFileBytes bytes\n',
      ),
    );
    final timestamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-');
    final target = File(
      '${exportDirectory.path}${Platform.pathSeparator}'
      'codepet-logs-$timestamp.zip',
    );
    await target.writeAsBytes(ZipEncoder().encode(archive), flush: true);
    await _pruneOldExports();
    return target.path;
  }

  Future<void> _convertLegacyLogs() async {
    for (final file in await _logFiles()) {
      final contents = utf8.decode(
        await file.readAsBytes(),
        allowMalformed: true,
      );
      if (!contents.trimLeft().startsWith('{')) continue;
      final modified = (await file.stat()).modified;
      final converted = normalizeLegacyLog(contents);
      final temporary = File('${file.path}.migrating');
      await temporary.writeAsString(converted, flush: true);
      await temporary.setLastModified(modified);
      await temporary.rename(file.path);
    }
  }

  Future<void> _rotateIfNeeded(int incomingBytes) async {
    final active = _activeFile;
    if (!await active.exists()) return;
    if (await active.length() + incomingBytes <= maxFileBytes) return;
    if (maxFileCount == 1) {
      await active.delete();
      return;
    }
    final oldest = _rotatedFile(maxFileCount - 1);
    if (await oldest.exists()) await oldest.delete();
    for (var index = maxFileCount - 2; index >= 1; index--) {
      final source = _rotatedFile(index);
      if (await source.exists()) {
        await source.rename(_rotatedFile(index + 1).path);
      }
    }
    await active.rename(_rotatedFile(1).path);
  }

  File _rotatedFile(int index) =>
      File('${logDirectory.path}${Platform.pathSeparator}codepet.$index.log');

  Future<List<File>> _logFiles() async {
    if (!await logDirectory.exists()) return const [];
    final files = await logDirectory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.log'))
        .cast<File>()
        .toList();
    files.sort((left, right) => left.path.compareTo(right.path));
    return files;
  }

  Future<void> _pruneExpired() async {
    final cutoff = DateTime.now().subtract(retention);
    for (final file in await _logFiles()) {
      if ((await file.stat()).modified.isBefore(cutoff)) {
        await file.delete();
      }
    }
    _nextRetentionCheck = DateTime.now().add(const Duration(hours: 1));
  }

  Future<void> _pruneOldExports() async {
    final files = await exportDirectory
        .list()
        .where((entity) => entity is File && entity.path.endsWith('.zip'))
        .cast<File>()
        .toList();
    files.sort((left, right) => right.path.compareTo(left.path));
    for (final file in files.skip(3)) {
      await file.delete();
    }
  }
}
