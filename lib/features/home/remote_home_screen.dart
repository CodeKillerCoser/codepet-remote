import 'package:flutter/material.dart';

import '../../devices/device_session.dart';
import '../../gateway/models.dart';
import '../conversations/conversation_detail_screen.dart';

class RemoteHomeScreen extends StatefulWidget {
  const RemoteHomeScreen({
    super.key,
    required this.sessions,
    required this.selectedIndex,
    required this.onSelectDevice,
    required this.onAddDevice,
    required this.onOpenSettings,
  });

  final List<DeviceSession> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelectDevice;
  final VoidCallback onAddDevice;
  final VoidCallback onOpenSettings;

  @override
  State<RemoteHomeScreen> createState() => _RemoteHomeScreenState();
}

class _RemoteHomeScreenState extends State<RemoteHomeScreen> {
  final Set<DeviceSession> _listenedSessions = {};

  @override
  void initState() {
    super.initState();
    _syncListeners();
  }

  @override
  void didUpdateWidget(RemoteHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncListeners();
  }

  void _syncListeners() {
    final desired = widget.sessions.toSet();
    for (final session in _listenedSessions.difference(desired)) {
      session.removeListener(_changed);
    }
    for (final session in desired.difference(_listenedSessions)) {
      session.addListener(_changed);
    }
    _listenedSessions
      ..clear()
      ..addAll(desired);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final session in _listenedSessions) {
      session.removeListener(_changed);
    }
    _listenedSessions.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = widget.sessions;
    final session = sessions.isEmpty ? null : sessions[widget.selectedIndex];
    return Scaffold(
      appBar: AppBar(
        title: const Text('CodePet Remote'),
        actions: [
          PopupMenuButton<String>(
            key: const Key('home-overflow-menu'),
            onSelected: (value) {
              if (value == 'connect') widget.onAddDevice();
              if (value == 'settings') widget.onOpenSettings();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'connect', child: Text('连接设备')),
              PopupMenuItem(value: 'settings', child: Text('App 设置')),
            ],
          ),
        ],
      ),
      body: sessions.isEmpty
          ? _EmptyDevices(onAddDevice: widget.onAddDevice)
          : RefreshIndicator(
              onRefresh: session!.connect,
              child: ListView(
                key: const Key('remote-home'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _DeviceSelector(
                    sessions: sessions,
                    selectedIndex: widget.selectedIndex,
                    onSelect: widget.onSelectDevice,
                  ),
                  const SizedBox(height: 12),
                  _DeviceActions(session: session),
                  const SizedBox(height: 28),
                  _SectionTitle(title: '项目', count: groupConversationsByWorkspace(session.conversations).length),
                  const SizedBox(height: 10),
                  ..._projectWidgets(context, session),
                  const SizedBox(height: 28),
                  _SectionTitle(title: '最近', count: session.conversations.length),
                  const SizedBox(height: 10),
                  ..._recentWidgets(context, session),
                ],
              ),
            ),
    );
  }

  List<Widget> _projectWidgets(BuildContext context, DeviceSession session) {
    if (session.connectionState == DeviceConnectionState.connecting &&
        session.conversations.isEmpty) {
      return const [LinearProgressIndicator()];
    }
    if (session.connectionState == DeviceConnectionState.failed) {
      return [
        _MessageCard(
          icon: Icons.cloud_off_outlined,
          title: '设备连接失败',
          message: session.error ?? '无法连接此设备。',
          actionLabel: '重新连接',
          onAction: session.connect,
        ),
      ];
    }
    if (session.connectionState == DeviceConnectionState.offline) {
      return [
        _MessageCard(
          icon: Icons.link_off_outlined,
          title: '设备已离线',
          message: '重新连接后，会话将从 Host 即时加载。',
          actionLabel: '连接',
          onAction: session.connect,
        ),
      ];
    }
    final projects = groupConversationsByWorkspace(session.conversations);
    if (projects.isEmpty) {
      return const [
        _MessageCard(
          icon: Icons.folder_off_outlined,
          title: '没有可分组的项目',
          message: '当前会话没有 workspaceRoot；它们仍会显示在“最近”中。',
        ),
      ];
    }
    return projects.entries.map((entry) {
      final name = entry.key.split(RegExp(r'[/\\]')).where((part) => part.isNotEmpty).last;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Card(
          margin: EdgeInsets.zero,
          elevation: 0,
          child: ListTile(
            key: Key('project-${entry.key}'),
            leading: const Icon(Icons.folder_outlined),
            title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${entry.value.length} 个会话 · ${entry.key}', maxLines: 1, overflow: TextOverflow.ellipsis),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push<void>(MaterialPageRoute(
              builder: (_) => _ProjectConversationsScreen(
                projectName: name,
                conversations: entry.value,
                session: session,
              ),
            )),
          ),
        ),
      );
    }).toList();
  }

  List<Widget> _recentWidgets(BuildContext context, DeviceSession session) {
    if (session.connectionState != DeviceConnectionState.online) return const [];
    if (session.conversations.isEmpty) {
      return const [
        _MessageCard(
          icon: Icons.forum_outlined,
          title: '还没有会话',
          message: '此设备当前没有可展示的会话。',
        ),
      ];
    }
    return session.conversations.map((conversation) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: _ConversationRow(
        conversation: conversation,
        onTap: () => _openConversation(context, session, conversation),
      ),
    )).toList();
  }
}

class _DeviceSelector extends StatelessWidget {
  const _DeviceSelector({required this.sessions, required this.selectedIndex, required this.onSelect});
  final List<DeviceSession> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 82,
      child: ListView.separated(
        key: const Key('device-selector'),
        scrollDirection: Axis.horizontal,
        itemCount: sessions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final session = sessions[index];
          final selected = index == selectedIndex;
          return ChoiceChip(
            key: Key('device-${session.device.deviceId}'),
            selected: selected,
            showCheckmark: false,
            onSelected: (_) => onSelect(index),
            label: SizedBox(
              width: 150,
              child: Row(children: [
                Icon(Icons.computer_outlined, color: selected ? Theme.of(context).colorScheme.onSecondaryContainer : null),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(session.device.effectiveName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 3),
                    Text(_deviceStateLabel(session.connectionState), style: Theme.of(context).textTheme.bodySmall),
                  ],
                )),
              ]),
            ),
          );
        },
      ),
    );
  }
}

class _DeviceActions extends StatelessWidget {
  const _DeviceActions({required this.session});
  final DeviceSession session;
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Expanded(child: Text(session.handshake == null ? '会话数据仅保留在本次连接中' : '${session.handshake!.serverName} · ${session.handshake!.serverVersion}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
      TextButton.icon(onPressed: session.connectionState == DeviceConnectionState.connecting ? null : session.connect, icon: const Icon(Icons.refresh, size: 18), label: const Text('重新连接')),
      PopupMenuButton<String>(
        tooltip: '设备管理',
        onSelected: (value) { if (value == 'disconnect') session.disconnect(); },
        itemBuilder: (_) => const [PopupMenuItem(value: 'disconnect', child: Text('断开设备'))],
      ),
    ]);
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.count});
  final String title;
  final int count;
  @override
  Widget build(BuildContext context) => Row(children: [
    Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
    const SizedBox(width: 8),
    Text('$count', style: Theme.of(context).textTheme.bodySmall),
  ]);
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.icon, required this.title, required this.message, this.actionLabel, this.onAction});
  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4), Text(message),
          if (onAction != null) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: onAction, child: Text(actionLabel!))),
        ])),
      ]),
    ),
  );
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({required this.conversation, required this.onTap});
  final ConversationSummary conversation;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    elevation: 0,
    child: ListTile(
      key: Key('conversation-${conversation.id}'),
      leading: Icon(conversation.status == ConversationStatus.running ? Icons.motion_photos_on_outlined : Icons.chat_bubble_outline),
      title: Text(conversation.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(conversation.preview ?? conversation.workspaceRoot ?? '无 workspaceRoot', maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(relativeConversationTime(conversation.updatedAt)),
      onTap: onTap,
    ),
  );
}

class _EmptyDevices extends StatelessWidget {
  const _EmptyDevices({required this.onAddDevice});
  final VoidCallback onAddDevice;
  @override
  Widget build(BuildContext context) => Center(child: Padding(
    padding: const EdgeInsets.all(24),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.devices_other_outlined, size: 48),
      const SizedBox(height: 16),
      const Text('还没有设备'),
      const SizedBox(height: 8),
      const Text('扫描 CodePet Host 显示的二维码，安全配对这台设备。', textAlign: TextAlign.center),
      const SizedBox(height: 20),
      FilledButton(onPressed: onAddDevice, child: const Text('连接设备')),
    ]),
  ));
}

class _ProjectConversationsScreen extends StatelessWidget {
  const _ProjectConversationsScreen({required this.projectName, required this.conversations, required this.session});
  final String projectName;
  final List<ConversationSummary> conversations;
  final DeviceSession session;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(projectName)),
    body: ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: conversations.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (_, index) => _ConversationRow(conversation: conversations[index], onTap: () => _openConversation(context, session, conversations[index])),
    ),
  );
}

void _openConversation(BuildContext context, DeviceSession session, ConversationSummary conversation) {
  Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ConversationDetailScreen(client: session.client, conversation: conversation)));
}

String _deviceStateLabel(DeviceConnectionState state) => switch (state) {
  DeviceConnectionState.offline => '离线',
  DeviceConnectionState.connecting => '连接中',
  DeviceConnectionState.online => '在线',
  DeviceConnectionState.failed => '连接失败',
};

String relativeConversationTime(DateTime value, {DateTime? now}) {
  final local = value.toLocal();
  final current = (now ?? DateTime.now()).toLocal();
  final day = DateTime(local.year, local.month, local.day);
  final today = DateTime(current.year, current.month, current.day);
  final difference = today.difference(day).inDays;
  final time = '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  if (difference == 0) return time;
  if (difference == 1) return '昨天';
  if (difference < 7 && difference > 1) return '$difference 天前';
  return '${local.month}/${local.day}';
}
