import 'dart:convert';

import 'package:codepet_remote/diagnostics/diagnostic_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Map<String, Object?> event(
    String time,
    String name, [
    Map<String, Object?> fields = const {},
  ]) => {
    'timestamp': time,
    'level': 'INFO',
    'logger': 'gateway.rtc.diagnostic',
    'schema': 'codepet.rtc.v1',
    'raceId': 'race-1',
    'event': name,
    ...fields,
  };
  test('legacy nested events and rotated shards produce chronological readable output', () {
    final start = event('2026-11-06T13:11:00Z', 'race.start');
    final failed = event('2026-11-06T13:11:40Z', 'race.path.result', {
      'path': 'relay',
      'outcome': 'failed',
      'cause': 'noCandidates',
      'durationMs': 40000,
    });
    final report = DiagnosticReport({
      'codepet.log': jsonEncode(failed),
      'codepet.1.log':
          '${jsonEncode({'timestamp': start['timestamp'], 'level': 'INFO', 'logger': 'gateway.rtc.diagnostic', 'message': jsonEncode(start)})}\ninvalid-tail',
    });
    expect(report.records.first['event'], 'race.start');
    expect(report.timeline, contains('WARN'));
    expect(report.timeline, isNot(contains(r'\"')));
    expect(report.summary, contains('TURN 中继：失败'));
    expect(report.summary, contains('截至导出尚无最终结果'));
    expect(
      report.summary,
      isNot(contains('486')),
    ); // A missing candidate alone cannot establish a server quota failure.
    expect(report.unreadable, ['codepet.1.log:2']);
  });
  test('successful race and expected cancellation do not become connection failure', () {
    final report = DiagnosticReport({
      'events': [
        event('1', 'race.target', {'targetId': 'device-hash'}),
        event('2', 'race.selected', {'path': 'lan', 'durationMs': 120}),
        event('3', 'race.path.result', {
          'path': 'relay',
          'outcome': 'cancelled',
          'durationMs': 120,
          'reason': 'anotherPathSelected',
        }),
      ].map(jsonEncode).join('\n'),
    });
    expect(report.summary, contains('通道选中 局域网'));
    expect(report.summary, contains('TURN 中继：已取消'));
    expect(report.summary, isNot(contains('各通道均未建立')));
  });
  test('detail snapshots remain out of the operational timeline; plain messages and errors remain', () {
    final report = DiagnosticReport({
      'events': [
        event('1', 'ice.stats', {
          'reports': [
            {'type': 'local-candidate', 'state': 'testing'},
          ],
        }),
        {
          'timestamp': '2',
          'level': 'WARNING',
          'logger': 'session',
          'message': 'Connection failed',
          'error': 'Socket failure',
        },
      ].map(jsonEncode).join('\n'),
    });
    expect(report.records.length, 2);
    expect(report.timeline, isNot(contains('ice.stats')));
    expect(
      report.timeline,
      contains('Connection failed | error=Socket failure'),
    );
    expect(report.summary, contains('最近 1 次连接'));
  });
}
