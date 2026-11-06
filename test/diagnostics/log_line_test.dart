import 'dart:convert';
import 'dart:io';

import 'package:codepet_remote/diagnostics/log_context.dart';
import 'package:codepet_remote/diagnostics/log_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('standard prefix, context and nested values remain readable text', () {
    final line = formatLogLine({
      'timestamp': '2026-11-06T21:11:12.216+08:00',
      'level': 'WARNING',
      'pid': 123,
      'threadId': 456,
      'sourceFile': 'transport.dart',
      'sourceLine': 72,
      'logger': 'rtc',
      'event': 'connect.failed',
      'offerId': 'abc',
      'stats': [
        {'state': 'failed'},
      ],
    });
    expect(
      line,
      startsWith(
        '2026-11-06 13:11:12.216+00:00 pid=123 thread=456 WARN  transport.dart:72 [rtc] connect.failed',
      ),
    );
    expect(line, contains('offerId=abc'));
    expect(line, contains('stats[0].state=failed'));
    expect(line, isNot(contains('{')));
  });
  test(
    'context is the producer and source-less stacks stay explicitly unknown',
    () {
      final context = LogContext.capture(StackTrace.current);
      expect(context['pid'], pid);
      expect(context['threadId'], greaterThan(0));
      expect(context['sourceFile'], contains('log_line_test.dart'));
      expect(context['sourceLine'], greaterThan(0));
      final unknown = LogContext.capture(
        StackTrace.fromString('0000 native offset'),
      );
      expect(unknown['sourceFile'], isNull);
      expect(unknown['sourceLine'], isNull);
    },
  );
  test(
    'control characters cannot inject lines; stack traces stay indented',
    () {
      final line = formatLogLine({
        'message': 'bad\u0000value\nforged\u001b[31m',
        'stackTrace': 'frame1\nframe2',
      });
      expect(line, contains('bad value forged [31m'));
      expect(line, endsWith('\n    frame1\n    frame2'));
      expect(line, isNot(contains('\u0000')));
    },
  );
  test(
    'legacy nested events retain correlation without made-up source fields',
    () {
      final converted = normalizeLegacyLog(
        jsonEncode({
          'timestamp': '2026-11-06T13:11:12.216Z',
          'level': 'INFO',
          'message': jsonEncode({
            'schema': 'codepet.rtc.v1',
            'event': 'race.path.result',
            'raceId': 'race-1',
            'outcome': 'cancelled',
          }),
        }),
      );
      expect(converted, contains('pid=- thread=- INFO  -:-'));
      expect(
        converted,
        contains('race.path.result | raceId=race-1 | outcome=cancelled'),
      );
      expect(converted, isNot(contains('{')));
    },
  );
}
