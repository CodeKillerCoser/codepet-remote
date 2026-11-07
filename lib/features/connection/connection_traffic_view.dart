import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/domain/connection_traffic.dart';

String connectionChannelLabel(String channel) => switch (channel) {
  'lan' => '局域网',
  'ipv6-direct' => 'IPv6 直连',
  'ipv4-direct' => 'IPv4 直连',
  'relay' => '中继',
  'direct' => '点对点直连',
  _ => '通道识别中',
};
String formatTrafficBytes(num bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes < 0 ? 0.0 : bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

/// Refresh only this small view; never rebuild conversation lists every second.
class ConnectionTrafficView extends StatefulWidget {
  const ConnectionTrafficView({
    super.key,
    required this.read,
    this.compact = false,
  });
  final ConnectionTraffic? Function() read;
  final bool compact;
  @override
  State<ConnectionTrafficView> createState() => _ConnectionTrafficViewState();
}

class _ConnectionTrafficViewState extends State<ConnectionTrafficView> {
  Timer? _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final traffic = widget.read();
    if (traffic == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Tooltip(
      message: '本机视角的应用数据量；速度为最近 3 秒平均值，不代表带宽上限',
      child: DefaultTextStyle(
        style: theme.textTheme.bodySmall!.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: widget.compact ? 6 : 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    connectionChannelLabel(traffic.channel),
                    style: TextStyle(
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Text('↑ ${formatTrafficBytes(traffic.sentBytesPerSecond)}/s'),
                  Text(
                    '↓ ${formatTrafficBytes(traffic.receivedBytesPerSecond)}/s',
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text('本次连接 ${formatTrafficBytes(traffic.totalBytes)}'),
              if (!widget.compact)
                Text(
                  '上传 ${formatTrafficBytes(traffic.sentBytes)} · 下载 ${formatTrafficBytes(traffic.receivedBytes)}',
                ),
            ],
          ),
        ),
      ),
    );
  }
}
