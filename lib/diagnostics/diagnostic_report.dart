import 'dart:convert';

/// Human-facing export of retained logs; accepts both flat and legacy nested events.
class DiagnosticReport {
  DiagnosticReport(Map<String, String> sources) {
    for (final source in sources.entries) {
      var lineNumber = 0;
      for (final line in const LineSplitter().convert(source.value)) {
        lineNumber++;
        if (line.trim().isEmpty) continue;
        try {
          final record = Map<String, dynamic>.from(jsonDecode(line) as Map);
          final message = record['message'];
          if (message is String && message.startsWith('{')) {
            try {
              final nested = Map<String, dynamic>.from(
                jsonDecode(message) as Map,
              );
              if (nested['schema'] == 'codepet.rtc.v1' &&
                  nested['event'] is String) {
                record.remove('message');
                record.addAll(nested);
              }
            } on FormatException {
              /* Plain text that resembles JSON remains text. */
            }
          }
          records.add(record);
        } catch (_) {
          unreadable.add('${source.key}:$lineNumber');
        }
      }
    }
    records.sort(
      (a, b) => '${a['timestamp'] ?? ''}'.compareTo('${b['timestamp'] ?? ''}'),
    );
  }

  final records = <Map<String, dynamic>>[];
  final unreadable = <String>[];

  static String clean(Object? value) =>
      '$value'.replaceAll(RegExp(r'[\r\n\t]'), ' ');
  static const paths = {
    'lan': '局域网',
    'ipv6-direct': 'IPv6 直连',
    'ipv4-direct': 'IPv4 直连',
    'relay': 'TURN 中继',
  };
  static const causes = {
    'noCandidates': '没有可用 ICE 候选（仅凭手机日志无法确定服务端拒绝原因）',
    'cloudAuthorizationMissing': '缺少此电脑的公网配对授权',
    'answerTimeout': '等待电脑应答结束；需结合取消事件区分超时与主动重连',
    'timeout': '等待超时',
    'socket': '网络套接字错误',
    'gatewayConnection': '通道建立失败',
    'tls': 'TLS 校验或握手失败',
    'http': 'HTTP 请求失败',
    'peerSignatureRejected': '对端签名校验失败',
  };
  static String reason(Map<String, dynamic> row) {
    final code = row['cause'];
    return code == null
        ? ''
        : '${causes[code] ?? clean(code)} [${clean(code)}]';
  }

  String get timeline {
    final out = StringBuffer(
      'CodePet Remote 运行日志（UTC，按时间排序）\n'
      '常规事件与失败见本文件；候选/统计完整明细见 raw/*.jsonl。\n\n',
    );
    for (final r in records) {
      final event = r['event'];
      if (const {'ice.stats', 'ice.localCandidate', 'span'}.contains(event)) {
        continue;
      }
      final level =
          event is String &&
              (event.endsWith('.failed') || r['outcome'] == 'failed')
          ? 'WARN'
          : r['level'] ?? 'INFO';
      out.write(
        '${r['timestamp'] ?? '时间未知'} ${clean(level).padRight(7)} [${clean(r['logger'] ?? 'app')}] ',
      );
      out.write(clean(event ?? r['message'] ?? '无消息'));
      final why = reason(r);
      if (why.isNotEmpty) out.write(' | $why');
      for (final key in [
        'raceId',
        'connectionId',
        'targetId',
        'offerId',
        'path',
        'pathPolicy',
        'stage',
        'state',
        'outcome',
        'reason',
        'method',
        'status',
        'durationMs',
        'elapsedMs',
        'previousStageMs',
        'candidateCount',
        'side',
        'attempt',
        'error',
        'errorType',
        'retryable',
        'osErrorCode',
        'serverCount',
        'policy',
      ]) {
        final value = r[key];
        if (value != null && value is! Map && value is! List) {
          out.write(' | $key=${clean(value)}');
        }
      }
      out.writeln();
      if (r['stackTrace'] != null) {
        for (final line in const LineSplitter().convert('${r['stackTrace']}')) {
          out.writeln('    ${clean(line)}');
        }
      }
    }
    if (unreadable.isNotEmpty) {
      out.writeln('\n无法解析的行（原文仍在 raw/）：${unreadable.join(', ')}');
    }
    return out.toString();
  }

  String get summary {
    final out = StringBuffer(
      'CodePet Remote 连接诊断摘要\n'
      '时间均为 UTC；北京时间为 UTC+8。摘要只陈述已记录事件，不推断 NAT 类型或运营商故障。\n',
    );
    if (records.isEmpty) {
      return '$out没有可解析记录；原始文件见 raw/。\n';
    }
    out.writeln(
      '日志范围：${records.first['timestamp']} ～ ${records.last['timestamp']}',
    );
    out.writeln('记录数：${records.length}；无法解析行：${unreadable.length}\n');
    final startup = records.where((r) => r['event'] == 'app.start').lastOrNull;
    out.writeln('构建：${startup?['buildRevision'] ?? '旧日志未记录'}；模式：${startup?['buildMode'] ?? '未知'}；平台：${startup?['platform'] ?? '未知'}');
    final races = <String, List<Map<String, dynamic>>>{};
    for (final r in records) {
      final id = r['raceId'];
      if (id is String) (races[id] ??= []).add(r);
    }
    final latest = races.entries.toList().reversed.take(20);
    if (races.isEmpty) out.writeln('没有连接竞速记录。');
    out.writeln('最近 ${races.length.clamp(0, 20)} 次连接（新到旧）：');
    for (final race in latest) {
      final rows = race.value;
      final selected = rows
          .where((r) => r['event'] == 'race.selected')
          .lastOrNull;
      final failed = rows.any((r) => r['event'] == 'race.failed');
      final cancelled = rows.any(
        (r) => r['event'] == 'race.path.result' && r['outcome'] == 'cancelled',
      );
      final target = rows
          .where((r) => r['event'] == 'race.target')
          .firstOrNull?['targetId'];
      out.writeln(
        '\n${rows.first['timestamp']}  ${race.key}\n  目标标识：${target ?? '未记录'}',
      );
      out.writeln(
        '  结果：${selected != null
            ? '通道选中 ${paths[selected['path']] ?? selected['path']}（业务握手另见时间线）'
            : failed
            ? '各通道均未建立'
            : cancelled
            ? '尝试被取消/替换；不等同于网络失败'
            : '截至导出尚无最终结果'}',
      );
      for (final path in paths.entries) {
        final result = rows
            .where(
              (r) => r['event'] == 'race.path.result' && r['path'] == path.key,
            )
            .lastOrNull;
        final stage = rows
            .where(
              (r) =>
                  r['event'] == 'connect.stage' && r['pathPolicy'] == path.key,
            )
            .lastOrNull;
        if (selected?['path'] == path.key) {
          out.writeln('  ${path.value}：已选中，${selected?['durationMs']} ms');
        } else if (result != null) {
          out.writeln(
            '  ${path.value}：${result['outcome'] == 'cancelled' ? '已取消' : '失败'}，${result['durationMs']} ms；${reason(result)}',
          );
        } else if (stage != null) {
          out.writeln('  ${path.value}：最后阶段 ${stage['stage']}，未记录结束');
        }
      }
      for (final r in rows.where(
        (r) => r['event'] == 'race.cloudLoad.failed',
      )) {
        out.writeln('  公网授权：${reason(r)}');
      }
      final offers = rows.map((r) => r['offerId']).whereType<String>().toSet();
      if (offers.isNotEmpty) {
        out.writeln('  对照电脑/VPS 的 offerId：${offers.join(', ')}');
      }
    }
    out.writeln('\n最近 20 条告警/错误（新到旧，详见 codepet.log）：');
    for (final r
        in records.reversed
            .where((r) => const {'WARNING', 'SEVERE'}.contains(r['level']))
            .take(20)) {
      out.writeln(
        '${r['timestamp']} ${clean(r['event'] ?? r['message'])} ${reason(r)} ${clean(r['error'] ?? '')}',
      );
    }
    return out.toString();
  }
}
