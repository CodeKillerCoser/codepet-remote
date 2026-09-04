import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.isEmpty || arguments.contains('--help')) {
    stderr.writeln(
      'Usage: dart run tool/trace_analyzer.dart [--trace TRACE_ID] '
      '<log.jsonl|diagnostics.zip>...',
    );
    exitCode = arguments.contains('--help') ? 0 : 64;
    return;
  }

  String? selectedTrace;
  final paths = <String>[];
  for (var index = 0; index < arguments.length; index++) {
    if (arguments[index] == '--trace') {
      if (index + 1 >= arguments.length) {
        stderr.writeln('--trace requires a trace ID');
        exitCode = 64;
        return;
      }
      selectedTrace = arguments[++index];
    } else {
      paths.add(arguments[index]);
    }
  }

  final records = <_TraceRecord>[];
  for (final path in paths) {
    final file = File(path);
    if (!await file.exists()) {
      stderr.writeln('Not found: $path');
      exitCode = 66;
      return;
    }
    if (path.toLowerCase().endsWith('.zip')) {
      final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
      for (final entry in archive.files.where((entry) => entry.isFile)) {
        final content = entry.content;
        _readLines(
          utf8.decode(content, allowMalformed: true),
          '$path:${entry.name}',
          records,
        );
      }
    } else {
      _readLines(await file.readAsString(), path, records);
    }
  }

  final traces = <String, List<_TraceRecord>>{};
  for (final record in records) {
    if (selectedTrace != null && record.traceId != selectedTrace) continue;
    traces.putIfAbsent(record.traceId, () => []).add(record);
  }
  if (traces.isEmpty) {
    stderr.writeln('No codepet.trace.v1 records found.');
    exitCode = 1;
    return;
  }

  final ordered = traces.entries.toList()
    ..sort((left, right) {
      final leftStart = _startOf(left.value);
      final rightStart = _startOf(right.value);
      return leftStart.compareTo(rightStart);
    });
  for (final trace in ordered) {
    trace.value.sort((left, right) => left.timestamp.compareTo(right.timestamp));
    final origin = trace.value.first.timestamp;
    stdout.writeln('\ntrace ${trace.key}  (${trace.value.length} records)');
    stdout.writeln('  offset(ms)  service   duration(ms)  name');
    for (final record in trace.value) {
      final offset = record.timestamp.difference(origin).inMicroseconds / 1000;
      final duration = record.durationUs == null
          ? '-'
          : (record.durationUs! / 1000).toStringAsFixed(1);
      stdout.writeln(
        '  ${offset.toStringAsFixed(1).padLeft(10)}  '
        '${record.service.padRight(8)}  '
        '${duration.padLeft(12)}  ${record.name}${record.summary}',
      );
    }
  }
}

DateTime _startOf(List<_TraceRecord> records) => records
    .map((record) => record.timestamp)
    .reduce((left, right) => left.isBefore(right) ? left : right);

void _readLines(String contents, String source, List<_TraceRecord> output) {
  for (final (index, line) in const LineSplitter().convert(contents).indexed) {
    if (!line.contains('codepet.trace.v1')) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) continue;
      final record = _TraceRecord.tryParse(decoded, source);
      if (record != null) output.add(record);
    } on FormatException catch (error) {
      stderr.writeln('$source:${index + 1}: invalid JSON: $error');
    }
  }
}

final class _TraceRecord {
  const _TraceRecord({
    required this.traceId,
    required this.timestamp,
    required this.service,
    required this.name,
    required this.source,
    this.durationUs,
    this.attributes = const {},
  });

  final String traceId;
  final DateTime timestamp;
  final String service;
  final String name;
  final String source;
  final int? durationUs;
  final Map<String, dynamic> attributes;

  String get summary {
    final values = <String>[];
    for (final key in const [
      'rpc.method',
      'event.name',
      'turn.id',
      'status',
    ]) {
      final value = attributes[key];
      if (value != null) values.add('$key=$value');
    }
    return values.isEmpty ? '' : '  ${values.join(' ')}';
  }

  static _TraceRecord? tryParse(Map<String, dynamic> json, String source) {
    if (json['schema'] != 'codepet.trace.v1') return null;
    final traceId = json['traceId'];
    final service = json['service'];
    final name = json['name'];
    if (traceId is! String || service is! String || name is! String) return null;
    final timestamp = _timestamp(json);
    if (timestamp == null) return null;
    final attributes = json['attributes'] is Map
        ? Map<String, dynamic>.from(json['attributes'] as Map)
        : <String, dynamic>{
            for (final entry in json.entries)
              if (!const {
                'timestamp',
                'timestampUnixUs',
                'schema',
                'recordType',
                'event',
                'service',
                'name',
                'traceId',
                'spanId',
                'parentSpanId',
                'startedAt',
                'durationUs',
              }.contains(entry.key))
                entry.key: entry.value,
          };
    return _TraceRecord(
      traceId: traceId,
      timestamp: timestamp,
      service: service,
      name: name,
      source: source,
      durationUs: _integer(json['durationUs'] ?? attributes['durationUs']),
      attributes: attributes,
    );
  }
}

DateTime? _timestamp(Map<String, dynamic> json) {
  final iso = json['startedAt'] ?? json['timestamp'];
  if (iso is String) return DateTime.tryParse(iso)?.toUtc();
  final unixUs = _integer(json['timestampUnixUs']);
  return unixUs == null
      ? null
      : DateTime.fromMicrosecondsSinceEpoch(unixUs, isUtc: true);
}

int? _integer(Object? value) => switch (value) {
      int number => number,
      String text => int.tryParse(text),
      _ => null,
    };
