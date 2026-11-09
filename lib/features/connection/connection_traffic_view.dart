import '../../ui/theme/app_semantics.dart';
import '../../ui/layout/app_layout.dart';
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
    if (widget.compact) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: Tooltip(
          message: '本机视角的应用数据量；速度为最近 3 秒平均值，不代表带宽上限',
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: AppLayout.space2),
            child: DefaultTextStyle(
              style: theme.textTheme.labelSmall!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
                letterSpacing: 0,
              ),
              child: Wrap(
                spacing: 6,
                runSpacing: 2,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    connectionChannelLabel(traffic.channel),
                    style: theme.trafficLabel,
                  ),
                  _TrafficValue(
                    key: const Key('traffic-upload'),
                    bytes: traffic.sentBytesPerSecond,
                    icon: Icons.arrow_upward,
                    label: '上传速度',
                    rate: true,
                  ),
                  _TrafficValue(
                    key: const Key('traffic-download'),
                    bytes: traffic.receivedBytesPerSecond,
                    icon: Icons.arrow_downward,
                    label: '下载速度',
                    rate: true,
                  ),
                  _TrafficValue(
                    key: const Key('traffic-total'),
                    bytes: traffic.totalBytes,
                    label: '本次连接传输数据量',
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return Tooltip(
      message: '本机视角的应用数据量；速度为最近 3 秒平均值，不代表带宽上限',
      child: DefaultTextStyle(
        style: theme.textTheme.bodySmall!.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AppLayout.space10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    connectionChannelLabel(traffic.channel),
                    style: theme.trafficBody,
                  ),
                  Text('↑ ${formatTrafficBytes(traffic.sentBytesPerSecond)}/s'),
                  Text(
                    '↓ ${formatTrafficBytes(traffic.receivedBytesPerSecond)}/s',
                  ),
                ],
              ),
              const SizedBox(height: AppLayout.space4),
              Text('本次连接 ${formatTrafficBytes(traffic.totalBytes)}'),
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

/// Keep each arrow, value and unit together without invisible fixed-width slots.
class _TrafficValue extends StatelessWidget {
  const _TrafficValue({
    super.key,
    required this.bytes,
    required this.label,
    this.icon,
    this.rate = false,
  });

  final num bytes;
  final String label;
  final IconData? icon;
  final bool rate;

  @override
  Widget build(BuildContext context) {
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB', 'EiB'];
    var value = bytes < 0 ? 0.0 : bytes.toDouble();
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
      value /= 1024;
      unit++;
    }
    // Four numeric characters cover the normal range; avoid 1023.9 taking
    // space from the next metric. Exact bytes remain in the detail view.
    final number = value.toStringAsFixed(unit == 0 || value >= 99.95 ? 0 : 1);
    final suffix = '${units[unit]}${rate ? '/s' : ''}';
    final style = DefaultTextStyle.of(context).style;
    final scaler = MediaQuery.textScalerOf(context);
    return Semantics(
      container: true,
      label: '$label ${formatTrafficBytes(bytes)}${rate ? '每秒' : ''}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: scaler.scale(11), color: style.color),
            const SizedBox(width: 1),
          ],
          Text(number, maxLines: 1),
          const SizedBox(width: AppLayout.space2),
          Text(suffix, maxLines: 1),
        ],
      ),
    );
  }
}
