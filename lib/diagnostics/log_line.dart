import 'dart:convert';

/// The same UTF-8 line format is used on disk and in exported logs.
String formatLogLine(Map<String, dynamic> record) {
  String clean(Object? value) =>
      '$value'.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ');
  final time = DateTime.tryParse('${record['timestamp']}')?.toUtc();
  final timestamp = time == null
      ? 'unknown-time'
      : '${time.toIso8601String().substring(0, 23).replaceFirst('T', ' ')}+00:00';
  final level = switch (record['level']) {
    'FINEST' || 'FINER' || 'FINE' => 'DEBUG',
    'WARNING' || 'WARN' => 'WARN',
    'SEVERE' || 'SHOUT' || 'ERROR' => 'ERROR',
    final String value => value,
    _ => 'INFO',
  };
  final out = StringBuffer(
    '$timestamp pid=${record['pid'] ?? '-'} '
    'thread=${record['threadId'] ?? '-'} '
    '${clean(level).padRight(5)} '
    '${clean(record['sourceFile'] ?? '-')}:${record['sourceLine'] ?? '-'} '
    '[${clean(record['logger'] ?? 'app')}] '
    '${clean(record['event'] ?? record['message'] ?? '')}',
  );
  const metadata = {
    'timestamp',
    'timestampUnixMs',
    'level',
    'pid',
    'threadId',
    'sourceFile',
    'sourceLine',
    'logger',
    'message',
    'event',
    'stackTrace',
    'recordType',
    'schema',
  };
  for (final entry in record.entries) {
    if (metadata.contains(entry.key) || entry.value == null) continue;
    void append(String key, Object? value) {
      if (value is Map) {
        for (final child in value.entries) {
          append('$key.${child.key}', child.value);
        }
      } else if (value is List) {
        out.write(' | ${clean(key)}.count=${value.length}');
        for (var index = 0; index < value.length; index++) {
          append('$key[$index]', value[index]);
        }
      } else {
        out.write(' | ${clean(key)}=${clean(value)}');
      }
    }

    append(entry.key, entry.value);
  }
  if (record['stackTrace'] != null) {
    for (final line in const LineSplitter().convert(
      '${record['stackTrace']}',
    )) {
      out.write('\n    ${clean(line)}');
    }
  }
  return out.toString();
}

/// One-time compatibility conversion. New records never pass through JSON.
String normalizeLegacyLog(String contents) {
  return '${const LineSplitter().convert(contents).map((line) {
    try {
      final record = Map<String, dynamic>.from(jsonDecode(line) as Map);
      final message = record['message'];
      if (message is String && message.startsWith('{')) {
        try {
          final nested = jsonDecode(message);
          if (nested is Map && nested['schema'] == 'codepet.rtc.v1') {
            record.remove('message');
            record.addAll(Map<String, dynamic>.from(nested));
          }
        } catch (_) {
          /* Preserve ordinary messages beginning with a brace. */
        }
      }
      return formatLogLine(record);
    } catch (_) {
      // Preserve damaged legacy rows as text, explicitly marked unparsed.
      return formatLogLine({'logger': 'legacy', 'level': 'WARNING', 'message': 'Unparsed legacy record', 'original': line});
    }
  }).join('\n')}\n';
}
