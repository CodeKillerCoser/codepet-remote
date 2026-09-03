import 'package:flutter/material.dart';

import '../../application/sessions/device_session.dart';

class DeviceConnectionNotice extends StatelessWidget {
  const DeviceConnectionNotice({
    super.key,
    required this.session,
  });

  final DeviceSession session;

  static bool shouldShow(DeviceSession session) =>
      session.connectionState == DeviceConnectionState.offline ||
      session.connectionState == DeviceConnectionState.failed;

  @override
  Widget build(BuildContext context) {
    final failed = session.connectionState == DeviceConnectionState.failed;
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      key: const Key('device-connection-notice'),
      margin: EdgeInsets.zero,
      color: failed
          ? colorScheme.errorContainer
          : colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                    '设备连接已断开',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    failed && session.error?.trim().isNotEmpty == true
                        ? session.error!
                        : '请前往设备详情重新连接。',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
