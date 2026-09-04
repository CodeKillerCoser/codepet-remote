import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/sessions/device_session.dart';

class DeviceConnectionNotice extends StatefulWidget {
  const DeviceConnectionNotice({
    super.key,
    required this.session,
    this.showReconnectAction = true,
  });

  final DeviceSession session;
  final bool showReconnectAction;

  static bool shouldShow(
    DeviceSession session, {
    bool includeConnecting = false,
  }) =>
      session.connectionState == DeviceConnectionState.offline ||
      session.connectionState == DeviceConnectionState.failed ||
      includeConnecting &&
          session.connectionState == DeviceConnectionState.connecting;

  @override
  State<DeviceConnectionNotice> createState() =>
      _DeviceConnectionNoticeState();
}

class _DeviceConnectionNoticeState extends State<DeviceConnectionNotice> {
  bool _reconnectAttempted = false;

  DeviceSession get session => widget.session;

  @override
  void didUpdateWidget(DeviceConnectionNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) {
      _reconnectAttempted = false;
    }
  }

  Future<void> _reconnect(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _reconnectAttempted = true;
    });
    await session.connect();
    final connected = session.connectionState == DeviceConnectionState.online;
    final error = session.error?.trim();
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            connected
                ? '设备已重新连接'
                : error?.isNotEmpty == true
                    ? '重新连接失败：$error'
                    : '重新连接失败，请稍后重试',
          ),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final failed = session.connectionState == DeviceConnectionState.failed;
    final connecting =
        session.connectionState == DeviceConnectionState.connecting;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('device-connection-notice'),
      margin: EdgeInsets.zero,
      color: failed
          ? colorScheme.errorContainer
          : colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (connecting)
                  const SizedBox.square(
                    dimension: 24,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                else
                  Icon(
                    failed ? Icons.cloud_off_outlined : Icons.link_off_outlined,
                    color: failed
                        ? colorScheme.onErrorContainer
                        : colorScheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        connecting
                            ? '正在连接设备'
                            : failed && _reconnectAttempted
                                ? '重新连接失败'
                                : '设备连接已断开',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        connecting
                            ? '正在尝试恢复连接，请稍候。'
                            : failed && session.error?.trim().isNotEmpty == true
                            ? session.error!
                            : widget.showReconnectAction
                                ? '请重新连接设备后继续。'
                                : '请前往设备详情重新连接。',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (widget.showReconnectAction) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  key: const Key('device-connection-reconnect'),
                  onPressed:
                      connecting ? null : () => unawaited(_reconnect(context)),
                  icon: connecting
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(connecting ? '连接中' : '重新连接'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
