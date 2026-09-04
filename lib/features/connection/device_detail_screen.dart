import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../application/sessions/device_session.dart';
import '../../core/domain/models.dart';
import '../common/identity_icons.dart';
import 'device_connection_notice.dart';

class DeviceDetailScreen extends StatefulWidget {
  const DeviceDetailScreen({super.key, required this.session});

  final DeviceSession session;

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  @override
  void didUpdateWidget(DeviceDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    oldWidget.session.removeListener(_changed);
    widget.session.addListener(_changed);
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final descriptor = session.device.descriptor;
    final providers = session.handshake?.providers ?? const <GatewayProvider>[];
    final connecting =
        session.connectionState == DeviceConnectionState.connecting;
    final online = session.connectionState == DeviceConnectionState.online;
    return Scaffold(
      appBar: AppBar(title: const Text('设备详情')),
      body: ListView(
        key: const Key('device-detail'),
        padding: const EdgeInsets.all(16),
        children: [
          Text(session.device.effectiveName,
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          _DetailCard(
            title: '设备信息',
            children: [
              _DetailRow(label: '名称', value: descriptor?.deviceName ?? session.device.displayName),
              _DetailRow(label: '系统', value: descriptor?.operatingSystem ?? '未知'),
              _DetailRow(label: '系统版本', value: descriptor?.systemVersion ?? '未知'),
              _DetailRow(label: '连接状态', value: _connectionLabel(session.connectionState)),
            ],
          ),
          if (DeviceConnectionNotice.shouldShow(session)) ...[
            const SizedBox(height: 12),
            DeviceConnectionNotice(
              session: session,
              showReconnectAction: false,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  key: const Key('device-reconnect'),
                  onPressed: connecting ? null : () => unawaited(session.connect()),
                  icon: connecting
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  label: Text(connecting ? '连接中' : '重新连接'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                key: const Key('device-disconnect'),
                onPressed: online ? () => unawaited(session.disconnect()) : null,
                icon: const Icon(Icons.link_off),
                label: const Text('断开连接'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Text('Provider', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 10),
          if (providers.isEmpty)
            const _DetailCard(
              title: '暂无 Provider 信息',
              children: [Text('连接设备后，握手返回的 Provider 信息会显示在这里。')],
            )
          else
            for (final provider in providers) ...[
              _ProviderDetailCard(provider: provider),
              const SizedBox(height: 10),
            ],
        ],
      ),
    );
  }
}

class _ProviderDetailCard extends StatelessWidget {
  const _ProviderDetailCard({required this.provider});

  final GatewayProvider provider;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ProviderIcon(
                    icon: provider.icon,
                    providerIdentity: provider.id,
                    size: 22,
                    semanticLabel: provider.displayName,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(provider.displayName,
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Text(_providerStatusLabel(provider.status)),
                ],
              ),
              const Divider(height: 24),
              _DetailRow(label: '版本', value: provider.runtimeVersion ?? '未提供'),
              _DetailRow(label: '路径', value: provider.executablePath ?? '未提供'),
              _DetailRow(
                label: '登录状态',
                value: provider.authenticationDisplayText ??
                    provider.authenticationStatus ??
                    '未提供',
              ),
              _DetailRow(label: '用量', value: provider.usageDisplayText ?? '未提供'),
              if (provider.usageDetails.isNotEmpty)
                ExpansionTile(
                  key: Key('provider-usage-details-${provider.id}'),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: EdgeInsets.zero,
                  title: const Text('原始用量数据'),
                  subtitle: const Text('协议透传，Remote 不解析其含义'),
                  children: [
                    for (final detail in provider.usageDetails)
                      SelectableText(
                        const JsonEncoder.withIndent('  ').convert(detail),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
            ],
          ),
        ),
      );
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const Divider(height: 24),
              ...children,
            ],
          ),
        ),
      );
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 88, child: Text(label)),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

String _connectionLabel(DeviceConnectionState state) => switch (state) {
      DeviceConnectionState.online => '在线',
      DeviceConnectionState.connecting => '连接中',
      DeviceConnectionState.offline => '离线',
      DeviceConnectionState.failed => '连接失败',
    };

String _providerStatusLabel(ProviderStatus status) => switch (status) {
      ProviderStatus.connecting => '连接中',
      ProviderStatus.ready => '可用',
      ProviderStatus.stopped => '已停止',
      ProviderStatus.unavailable => '不可用',
      ProviderStatus.error => '错误',
    };
