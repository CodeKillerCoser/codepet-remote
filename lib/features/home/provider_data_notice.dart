import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/sessions/device_session.dart';

/// Business errors stay beside the selected Provider, never in the device's
/// connection notice. Existing lists remain visible below this notice.
class ProviderDataNotice extends StatelessWidget {
  const ProviderDataNotice({super.key, required this.session});

  final DeviceSession session;

  @override
  Widget build(BuildContext context) {
    final provider = session.selectedProvider;
    if (provider == null ||
        !provider.isAvailable ||
        session.connectionState != DeviceConnectionState.online) {
      return const SizedBox.shrink();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final kind in ProviderDataKind.values)
          if (session.providerData(provider.id, kind).status
              case ProviderDataStatus.loading || ProviderDataStatus.failed)
            _notice(context, provider.id, kind),
      ],
    );
  }

  Widget _notice(BuildContext context, String id, ProviderDataKind kind) {
    final state = session.providerData(id, kind);
    final loading = state.status == ProviderDataStatus.loading;
    final title = switch (kind) {
      ProviderDataKind.capabilities => '智能体信息',
      ProviderDataKind.projects => '项目',
      ProviderDataKind.conversations => '对话',
    };
    return Semantics(
      liveRegion: true,
      child: Card(
        key: ValueKey('provider-data-$id-${kind.name}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(child: Text('$title${loading ? '加载中' : '加载失败'}')),
                  if (loading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    TextButton.icon(
                      key: ValueKey('retry-provider-$id-${kind.name}'),
                      onPressed: () =>
                          unawaited(session.retryProviderData(id, kind)),
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                ],
              ),
              if (state.error != null)
                Text(
                  state.error!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
