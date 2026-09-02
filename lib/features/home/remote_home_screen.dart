import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/sessions/device_session.dart';
import '../../core/domain/models.dart';
import '../common/identity_icons.dart';
import '../conversations/conversation_detail_screen.dart';
import '../conversations/conversation_search_screen.dart';

const int _projectPageSize = 6;
const int _conversationPageSize = 8;
const int _recentPageSize = 20;

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
  final Map<String, _DeviceHomeViewState> _deviceViewStates = {};

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

  Future<void> _advanceWindow({
    required DeviceSession session,
    required bool hasLocalMore,
    required VoidCallback advance,
  }) async {
    if (session.isLoadingMoreConversations) return;
    if (session.canLoadMoreSelectedProviderConversations) {
      await session.loadMoreSelectedProviderConversations();
      if (!mounted ||
          session.connectionState != DeviceConnectionState.online ||
          session.loadMoreError != null) {
        return;
      }
    } else if (!hasLocalMore) {
      return;
    }
    setState(advance);
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
    final selectedIndex = sessions.isEmpty
        ? 0
        : widget.selectedIndex < 0
            ? 0
            : widget.selectedIndex >= sessions.length
                ? sessions.length - 1
                : widget.selectedIndex;
    final session = sessions.isEmpty ? null : sessions[selectedIndex];
    final selectedProvider = session?.selectedProvider;
    final selectedConversations = session == null
        ? const <ConversationSummary>[]
        : session.selectedProviderConversations;
    final projects = session == null
        ? const <ConversationProject>[]
        : _sortedProjects(session, selectedConversations);
    final recent = session == null
        ? const <ConversationSummary>[]
        : sortRecentConversations(
            deduplicateRoutedConversations(selectedConversations),
          );
    final viewState = session == null
        ? null
        : _deviceViewStates.putIfAbsent(
            '${session.device.deviceId}\u0000${selectedProvider?.route.key ?? 'no-provider'}',
            _DeviceHomeViewState.new,
          );
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
                    selectedIndex: selectedIndex,
                    onSelect: widget.onSelectDevice,
                  ),
                  const SizedBox(height: 12),
                  _DeviceActions(
                    session: session,
                    selectedProvider: selectedProvider,
                    onSelectProvider: session.selectProvider,
                  ),
                  const SizedBox(height: 28),
                  _SectionTitle(
                    key: Key('projects-section-${session.device.deviceId}'),
                    title: '项目',
                    countLabel:
                        '${projects.length}${session.canLoadMoreSelectedProviderConversations ? '+' : ''}',
                    expanded: viewState!.projectsExpanded,
                    onTap: () => setState(() {
                      viewState.projectsExpanded = !viewState.projectsExpanded;
                    }),
                  ),
                  if (viewState.projectsExpanded) ...[
                    const SizedBox(height: 10),
                    ..._projectWidgets(context, session, projects, viewState),
                  ],
                  const SizedBox(height: 28),
                  _SectionTitle(
                    key: Key('recent-section-${session.device.deviceId}'),
                    title: '最近',
                    countLabel: session.selectedProviderConversationCountLabel,
                    expanded: viewState.recentExpanded,
                    onTap: () => setState(() {
                      viewState.recentExpanded = !viewState.recentExpanded;
                    }),
                  ),
                  if (viewState.recentExpanded) ...[
                    const SizedBox(height: 10),
                    ..._recentWidgets(context, session, recent, viewState),
                  ],
                ],
              ),
            ),
      bottomNavigationBar: session == null
          ? null
          : _ConversationActionsBar(
              searchKey: const Key('home-search'),
              createKey: const Key('home-new'),
              canSearch: selectedProvider != null,
              canCreate: selectedProvider?.status == ProviderStatus.ready &&
                  selectedProvider?.methods
                          .contains('conversation.create') ==
                      true,
              onSearch: () => _openSearch(context, session),
              onCreate: selectedProvider == null
                  ? null
                  : () => _startConversation(
                        context,
                        session: session,
                        provider: selectedProvider,
                      ),
            ),
    );
  }

  List<Widget> _projectWidgets(
    BuildContext context,
    DeviceSession session,
    List<ConversationProject> projects,
    _DeviceHomeViewState viewState,
  ) {
    if (session.connectionState == DeviceConnectionState.connecting &&
        session.selectedProviderConversations.isEmpty) {
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
    if (projects.isEmpty) {
      return [
        const _MessageCard(
          icon: Icons.folder_off_outlined,
          title: '没有可分组的项目',
          message: '当前会话没有 workspaceRoot；它们仍会显示在“最近”中。',
        ),
        if (session.canLoadMoreSelectedProviderConversations ||
            session.isLoadingMoreConversations)
          _PaginationControl(
            buttonKey: Key(
              'show-more-projects-${session.device.deviceId}',
            ),
            label: '显示更多项目',
            loading: session.isLoadingMoreConversations,
            error: session.loadMoreError,
            onPressed: () {
              unawaited(_advanceWindow(
                session: session,
                hasLocalMore: false,
                advance: () => viewState.projectPages++,
              ));
            },
          ),
      ];
    }
    final requestedCount = viewState.projectPages * _projectPageSize;
    final visibleCount = requestedCount < projects.length
        ? requestedCount
        : projects.length;
    final widgets = <Widget>[];
    widgets.addAll(projects.take(visibleCount).map((project) {
      final pathParts = project.workspaceRoot
          .split(RegExp(r'[/\\]'))
          .where((part) => part.isNotEmpty)
          .toList(growable: false);
      final name = pathParts.isEmpty ? project.workspaceRoot : pathParts.last;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _ProjectCard(
            key: Key('project-card-${project.key}'),
            project: project,
            projectName: name,
            canLoadMore: session.canLoadMoreSelectedProviderConversations,
            onOpenProject: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => _ProjectConversationsScreen(
                  projectName: name,
                  workspaceRoot: project.workspaceRoot,
                  session: session,
                ),
              ),
            ),
        ),
      );
    }));
    if (visibleCount < projects.length ||
        session.canLoadMoreSelectedProviderConversations ||
        session.isLoadingMoreConversations) {
      widgets.add(
        _PaginationControl(
          buttonKey: Key('show-more-projects-${session.device.deviceId}'),
          label: '显示更多项目',
          loading: session.isLoadingMoreConversations,
          error: visibleCount < projects.length ? null : session.loadMoreError,
          onPressed: () {
            unawaited(_advanceWindow(
              session: session,
              hasLocalMore: visibleCount < projects.length,
              advance: () => viewState.projectPages++,
            ));
          },
        ),
      );
    }
    return widgets;
  }

  List<Widget> _recentWidgets(
    BuildContext context,
    DeviceSession session,
    List<ConversationSummary> recent,
    _DeviceHomeViewState viewState,
  ) {
    if (session.connectionState != DeviceConnectionState.online) return const [];
    if (recent.isEmpty) {
      return [
        const _MessageCard(
          icon: Icons.forum_outlined,
          title: '还没有会话',
          message: '此设备当前没有可展示的会话。',
        ),
        if (session.canLoadMoreSelectedProviderConversations ||
            session.isLoadingMoreConversations)
          _PaginationControl(
            buttonKey: Key('show-more-recent-${session.device.deviceId}'),
            label: '显示更多对话',
            loading: session.isLoadingMoreConversations,
            error: session.loadMoreError,
            onPressed: () {
              unawaited(_advanceWindow(
                session: session,
                hasLocalMore: false,
                advance: () => viewState.recentPages++,
              ));
            },
          ),
      ];
    }
    final requestedCount = viewState.recentPages * _recentPageSize;
    final visibleCount = requestedCount < recent.length
        ? requestedCount
        : recent.length;
    final widgets = <Widget>[];
    widgets.addAll(recent.take(visibleCount).map((conversation) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ConversationRow(
              key: Key(
                'recent-conversation-${session.device.deviceId}-${conversationRoutingKey(conversation)}',
              ),
              session: session,
              conversation: conversation,
              onTap: (current) =>
                  _openConversation(context, session, current),
          ),
        )));
    if (visibleCount < recent.length ||
        session.canLoadMoreSelectedProviderConversations ||
        session.isLoadingMoreConversations) {
      widgets.add(
        _PaginationControl(
          buttonKey: Key('show-more-recent-${session.device.deviceId}'),
          label: '显示更多对话',
          loading: session.isLoadingMoreConversations,
          error: visibleCount < recent.length ? null : session.loadMoreError,
          onPressed: () {
            unawaited(_advanceWindow(
              session: session,
              hasLocalMore: visibleCount < recent.length,
              advance: () => viewState.recentPages++,
            ));
          },
        ),
      );
    }
    return widgets;
  }
}

class _DeviceHomeViewState {
  bool projectsExpanded = true;
  bool recentExpanded = true;
  int projectPages = 1;
  int recentPages = 1;
}

List<ConversationProject> _sortedProjects(
  DeviceSession session,
  Iterable<ConversationSummary> conversations,
) {
  final projects = groupConversationsByProject(
    hostDeviceId: session.device.deviceId,
    values: conversations,
  );
  return projects
    ..sort((left, right) {
      final updated = right.conversations.first.updatedAt
          .compareTo(left.conversations.first.updatedAt);
      return updated != 0
          ? updated
          : left.workspaceRoot.compareTo(right.workspaceRoot);
    });
}

class _DeviceSelector extends StatelessWidget {
  const _DeviceSelector({required this.sessions, required this.selectedIndex, required this.onSelect});
  final List<DeviceSession> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 62,
      child: ListView.separated(
        key: const Key('device-selector'),
        scrollDirection: Axis.horizontal,
        itemCount: sessions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final session = sessions[index];
          final descriptor = session.handshake?.deviceDescriptor ??
              session.device.descriptor;
          final alias = session.device.alias?.trim();
          final deviceName = alias?.isNotEmpty == true
              ? alias!
              : descriptor?.deviceName ?? session.device.displayName;
          final systemLabel = descriptor == null
              ? _deviceStateLabel(session.connectionState)
              : '${descriptor.operatingSystem} ${descriptor.systemVersion}';
          final selected = index == selectedIndex;
          final colorScheme = Theme.of(context).colorScheme;
          return Semantics(
            key: Key('device-${session.device.deviceId}'),
            button: true,
            selected: selected,
            label: '$deviceName，$systemLabel，${_deviceStateLabel(session.connectionState)}',
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => onSelect(index),
                borderRadius: BorderRadius.circular(16),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  width: 158,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: selected
                        ? colorScheme.secondaryContainer
                        : colorScheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: selected
                          ? colorScheme.primary.withValues(alpha: 0.55)
                          : colorScheme.outlineVariant,
                    ),
                  ),
                  child: Row(
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color: selected
                                  ? colorScheme.primary.withValues(alpha: 0.12)
                                  : colorScheme.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(11),
                            ),
                            alignment: Alignment.center,
                            child: Icon(
                              operatingSystemIconData(
                                descriptor?.operatingSystem ??
                                    session.device.displayName,
                              ),
                              size: 22,
                              color: selected
                                  ? colorScheme.primary
                                  : colorScheme.onSurfaceVariant,
                            ),
                          ),
                          Positioned(
                            right: -2,
                            bottom: -2,
                            child: Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(
                                color: _deviceStateColor(
                                  colorScheme,
                                  session.connectionState,
                                ),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected
                                      ? colorScheme.secondaryContainer
                                      : colorScheme.surfaceContainerLow,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              deviceName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodyMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              systemLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

Color _deviceStateColor(
  ColorScheme colorScheme,
  DeviceConnectionState state,
) => switch (state) {
      DeviceConnectionState.online => Colors.green.shade600,
      DeviceConnectionState.connecting => colorScheme.tertiary,
      DeviceConnectionState.offline => colorScheme.outline,
      DeviceConnectionState.failed => colorScheme.error,
    };

class _DeviceActions extends StatelessWidget {
  const _DeviceActions({
    required this.session,
    required this.selectedProvider,
    required this.onSelectProvider,
  });
  final DeviceSession session;
  final GatewayProvider? selectedProvider;
  final ValueChanged<GatewayProvider> onSelectProvider;
  @override
  Widget build(BuildContext context) {
    final handshake = session.handshake;
    final providers = handshake?.providers ?? const <GatewayProvider>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (providers.isNotEmpty) ...[
          SizedBox(
            height: 42,
            child: ListView.separated(
              key: const Key('connected-providers'),
              scrollDirection: Axis.horizontal,
              itemCount: providers.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final provider = providers[index];
                return _ProviderIdentity(
                  provider: provider,
                  selected: provider.route == selectedProvider?.route,
                  onSelected: onSelectProvider,
                );
              },
            ),
          ),
          const SizedBox(height: 4),
        ],
        Row(children: [
          Expanded(child: Text(
            handshake == null
                ? '会话数据仅保留在本次连接中'
                : '${handshake.serverName} · ${handshake.serverVersion}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          )),
          TextButton.icon(
            onPressed: session.connectionState == DeviceConnectionState.connecting
                ? null
                : session.connect,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('重新连接'),
          ),
          PopupMenuButton<String>(
            tooltip: '设备管理',
            onSelected: (value) {
              if (value == 'disconnect') session.disconnect();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'disconnect', child: Text('断开设备')),
            ],
          ),
        ]),
      ],
    );
  }
}

class _ProviderIdentity extends StatelessWidget {
  const _ProviderIdentity({
    required this.provider,
    required this.selected,
    required this.onSelected,
  });

  final GatewayProvider provider;
  final bool selected;
  final ValueChanged<GatewayProvider> onSelected;

  @override
  Widget build(BuildContext context) {
    final ready = provider.status == ProviderStatus.ready;
    return ChoiceChip(
      key: Key('provider-${provider.route.key}'),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(provider),
      visualDensity: VisualDensity.compact,
      avatar: Icon(
        providerIconData(provider.icon ?? provider.providerType),
        size: 17,
        color: ready
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
      ),
      label: Text(provider.displayName),
      side: BorderSide(
        color: ready
            ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.35)
            : Theme.of(context).colorScheme.outlineVariant,
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({
    super.key,
    required this.title,
    required this.countLabel,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final String countLabel;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Expanded(
            child: Row(children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(width: 8),
              Text(countLabel, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
          Icon(
            expanded ? Icons.expand_less : Icons.expand_more,
            semanticLabel: expanded ? '折叠$title' : '展开$title',
          ),
        ]),
      ),
    ),
  );
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({
    super.key,
    required this.project,
    required this.projectName,
    required this.canLoadMore,
    required this.onOpenProject,
  });

  final ConversationProject project;
  final String projectName;
  final bool canLoadMore;
  final VoidCallback onOpenProject;

  @override
  Widget build(BuildContext context) {
    final conversations = sortRecentConversations(project.conversations);
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        key: Key('project-${project.key}'),
        leading: const Icon(Icons.folder_outlined),
        title: Text(
          projectName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${conversations.length}${canLoadMore ? '+' : ''} 个会话 · ${project.workspaceRoot}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onOpenProject,
      ),
    );
  }
}

class _PaginationControl extends StatelessWidget {
  const _PaginationControl({
    required this.buttonKey,
    required this.label,
    required this.loading,
    required this.error,
    required this.onPressed,
  });

  final Key buttonKey;
  final String label;
  final bool loading;
  final String? error;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null) ...[
              const SizedBox(height: 4),
              Text(
                '加载失败：$error',
                textAlign: TextAlign.center,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            TextButton.icon(
              key: buttonKey,
              onPressed: loading ? null : onPressed,
              icon: loading
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more),
              label: Text(loading ? '加载中…' : label),
            ),
          ],
        ),
      );
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
  const _ConversationRow({
    super.key,
    required this.session,
    required this.conversation,
    required this.onTap,
  });

  final DeviceSession session;
  final ConversationSummary conversation;
  final ValueChanged<ConversationSummary> onTap;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        child: _LiveConversationTile(
          key: Key('conversation-${conversation.id}'),
          session: session,
          conversation: conversation,
          onTap: onTap,
        ),
      );
}

class _LiveConversationTile extends StatelessWidget {
  const _LiveConversationTile({
    super.key,
    required this.session,
    required this.conversation,
    required this.onTap,
  });

  final DeviceSession session;
  final ConversationSummary conversation;
  final ValueChanged<ConversationSummary> onTap;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ConversationSummary>(
        valueListenable: session.conversationListenable(conversation),
        builder: (context, current, _) => _ConversationTile(
          conversation: current,
          onTap: () => onTap(current),
        ),
      );
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    required this.conversation,
    required this.onTap,
  });

  final ConversationSummary conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(
          conversation.status == ConversationStatus.running
              ? Icons.motion_photos_on_outlined
              : Icons.chat_bubble_outline,
        ),
        title: Text(
          conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          conversation.preview ??
              conversation.workspaceRoot ??
              '无 workspaceRoot',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(relativeConversationTime(conversation.updatedAt)),
        onTap: onTap,
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

class _ProjectConversationsScreen extends StatefulWidget {
  const _ProjectConversationsScreen({
    required this.projectName,
    required this.workspaceRoot,
    required this.session,
  });

  final String projectName;
  final String workspaceRoot;
  final DeviceSession session;

  @override
  State<_ProjectConversationsScreen> createState() =>
      _ProjectConversationsScreenState();
}

class _ProjectConversationsScreenState
    extends State<_ProjectConversationsScreen> {
  int _pages = 1;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
  }

  @override
  void didUpdateWidget(_ProjectConversationsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session) return;
    oldWidget.session.removeListener(_changed);
    widget.session.addListener(_changed);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_changed);
    super.dispose();
  }

  Future<void> _showMore({required bool hasLocalMore}) async {
    if (widget.session.isLoadingMoreConversations) return;
    if (widget.session.canLoadMoreSelectedProviderConversations) {
      await widget.session.loadMoreSelectedProviderConversations();
      if (!mounted ||
          widget.session.connectionState != DeviceConnectionState.online ||
          widget.session.loadMoreError != null) {
        return;
      }
    } else if (!hasLocalMore) {
      return;
    }
    setState(() {
      _pages++;
    });
  }

  List<ConversationSummary> _projectConversations() =>
      sortRecentConversations(
        deduplicateRoutedConversations(
          widget.session.selectedProviderConversations.where(
            (conversation) =>
                conversation.workspaceRoot == widget.workspaceRoot,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final conversations = _projectConversations();
    final requestedCount = _pages * _conversationPageSize;
    final visibleCount = requestedCount < conversations.length
        ? requestedCount
        : conversations.length;
    final hasLocalMore = visibleCount < conversations.length;
    final hasMore = hasLocalMore ||
        widget.session.canLoadMoreSelectedProviderConversations ||
        widget.session.isLoadingMoreConversations;
    final selectedProvider = widget.session.selectedProvider;
    return Scaffold(
      appBar: AppBar(title: Text(widget.projectName)),
      body: ListView.separated(
        key: const Key('project-conversation-list'),
        padding: const EdgeInsets.all(16),
        itemCount: visibleCount + (hasMore ? 1 : 0),
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, index) {
          if (index == visibleCount) {
            return Center(
              child: _PaginationControl(
                buttonKey: const Key(
                  'show-more-project-screen-conversations',
                ),
                label: '显示更多对话',
                loading: widget.session.isLoadingMoreConversations,
                error: hasLocalMore ? null : widget.session.loadMoreError,
                onPressed: () {
                  unawaited(_showMore(hasLocalMore: hasLocalMore));
                },
              ),
            );
          }
          final conversation = conversations[index];
          return _ConversationRow(
            key: Key(
              'project-screen-conversation-${conversationRoutingKey(conversation)}',
            ),
            session: widget.session,
            conversation: conversation,
            onTap: (current) => _openConversation(
              context,
              widget.session,
              current,
            ),
          );
        },
      ),
      bottomNavigationBar: _ConversationActionsBar(
        searchKey: const Key('project-search'),
        createKey: const Key('project-new'),
        canSearch: selectedProvider != null,
        canCreate: selectedProvider?.status == ProviderStatus.ready &&
            selectedProvider?.methods.contains('conversation.create') == true,
        onSearch: () => _openSearch(
          context,
          widget.session,
          workspaceRoot: widget.workspaceRoot,
        ),
        onCreate: selectedProvider == null
            ? null
            : () => _startConversation(
                  context,
                  session: widget.session,
                  provider: selectedProvider,
                  workspaceRoot: widget.workspaceRoot,
                ),
      ),
    );
  }
}

class _ConversationActionsBar extends StatelessWidget {
  const _ConversationActionsBar({
    required this.searchKey,
    required this.createKey,
    required this.canSearch,
    required this.canCreate,
    required this.onSearch,
    required this.onCreate,
  });

  final Key searchKey;
  final Key createKey;
  final bool canSearch;
  final bool canCreate;
  final VoidCallback onSearch;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) => Material(
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          minimum: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: searchKey,
                  onPressed: canSearch ? onSearch : null,
                  icon: const Icon(Icons.search),
                  label: const Text('搜索'),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                key: createKey,
                onPressed: canCreate ? onCreate : null,
                icon: const Icon(Icons.add),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
      );
}

class _NewConversationDialog extends StatefulWidget {
  const _NewConversationDialog({
    required this.session,
    required this.provider,
    this.workspaceRoot,
  });

  final DeviceSession session;
  final GatewayProvider provider;
  final String? workspaceRoot;

  @override
  State<_NewConversationDialog> createState() =>
      _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _workspaceController;
  String? _permissionLevel;
  String? _reasoningEffort;
  String? _model;
  String? _workspaceMode;
  bool _creating = false;
  String? _error;

  ConversationCreateCapabilities? get _createCapabilities =>
      widget.provider.capabilities.conversationCreate;

  TurnSendCapabilities? get _selectionCapabilities =>
      _createCapabilities?.selection ?? widget.provider.capabilities.turnSend;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _workspaceController = TextEditingController(text: widget.workspaceRoot);
    final selection = _selectionCapabilities;
    _permissionLevel = _initialChoice(selection?.accessMode) ??
        PermissionLevel.workspaceWrite;
    _reasoningEffort = _initialChoice(selection?.reasoningEffort);
    final catalog = selection?.modelCatalog;
    final modelSelection = catalog?.defaultSelection ??
        (catalog?.availableSelections.isNotEmpty == true
            ? catalog!.availableSelections.first
            : null);
    _model = catalog?.modelFor(modelSelection)?.id;
    _workspaceMode = _initialChoice(_createCapabilities?.workspaceMode);
  }

  String? _initialChoice(ProviderChoiceSet? choices) =>
      choices?.defaultId ??
      (choices?.availableOptions.isNotEmpty == true
          ? choices!.availableOptions.first.id
          : null);

  @override
  void dispose() {
    _titleController.dispose();
    _workspaceController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    if (_creating) return;
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final conversation = await widget.session.createConversation(
        provider: widget.provider,
        title: _titleController.text,
        workspaceRoot: _workspaceController.text,
        permissionLevel: _permissionLevel,
        reasoningEffort: _reasoningEffort,
        model: _model,
        workspaceMode: _workspaceMode,
      );
      if (mounted) Navigator.of(context).pop(conversation);
    } catch (error) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('在 ${widget.provider.displayName} 中新建会话'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_createCapabilities?.supportsTitle != false) ...[
                TextField(
                  key: const Key('new-conversation-title'),
                  controller: _titleController,
                  enabled: !_creating,
                  decoration: const InputDecoration(
                    labelText: '标题（可选）',
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(
                key: const Key('new-conversation-workspace'),
                controller: _workspaceController,
                enabled: !_creating && widget.workspaceRoot == null,
                decoration: const InputDecoration(
                  labelText: '工作区路径（可选）',
                  prefixIcon: Icon(Icons.folder_outlined),
                ),
              ),
              if (_createCapabilities?.workspaceMode != null) ...[
                const SizedBox(height: 12),
                _choiceField(
                  key: const Key('new-conversation-workspace-mode'),
                  label: '工作区模式',
                  choices: _createCapabilities!.workspaceMode!,
                  value: _workspaceMode,
                  onChanged: (value) => setState(() {
                    _workspaceMode = value;
                  }),
                ),
              ],
              if (_selectionCapabilities?.accessMode != null) ...[
                const SizedBox(height: 12),
                _choiceField(
                  key: const Key('new-conversation-access-mode'),
                  label: '访问模式',
                  choices: _selectionCapabilities!.accessMode!,
                  value: _permissionLevel,
                  onChanged: (value) => setState(() {
                    _permissionLevel = value;
                  }),
                ),
              ],
              if (_selectionCapabilities?.reasoningEffort != null) ...[
                const SizedBox(height: 12),
                _choiceField(
                  key: const Key('new-conversation-reasoning-effort'),
                  label: '推理强度',
                  choices: _selectionCapabilities!.reasoningEffort!,
                  value: _reasoningEffort,
                  onChanged: (value) => setState(() {
                    _reasoningEffort = value;
                  }),
                ),
              ],
              if (_selectionCapabilities?.modelCatalog != null) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('new-conversation-model'),
                  initialValue: _model,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: '模型'),
                  items: [
                    for (final selection in _selectionCapabilities!
                        .modelCatalog!
                        .availableSelections)
                      DropdownMenuItem(
                        value: _selectionCapabilities!.modelCatalog!
                            .modelFor(selection)!
                            .id,
                        child: Text(
                          _selectionCapabilities!.modelCatalog!
                              .modelFor(selection)!
                              .displayName,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _creating
                      ? null
                      : (value) => setState(() {
                            _model = value;
                          }),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _creating ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-new-conversation'),
            onPressed: _creating ? null : _create,
            child: _creating
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('创建'),
          ),
        ],
      );

  Widget _choiceField({
    required Key key,
    required String label,
    required ProviderChoiceSet choices,
    required String? value,
    required ValueChanged<String?> onChanged,
  }) {
    final options = choices.availableOptions;
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      items: [
        for (final option in options)
          DropdownMenuItem(
            value: option.id,
            child: Text(option.displayName, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _creating || options.length < 2 ? null : onChanged,
    );
  }
}

void _openSearch(
  BuildContext context,
  DeviceSession session, {
  String? workspaceRoot,
}) {
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ConversationSearchScreen(
        session: session,
        workspaceRoot: workspaceRoot,
      ),
    ),
  );
}

Future<void> _startConversation(
  BuildContext context, {
  required DeviceSession session,
  required GatewayProvider provider,
  String? workspaceRoot,
}) async {
  final conversation = await showDialog<ConversationSummary>(
    context: context,
    builder: (_) => _NewConversationDialog(
      session: session,
      provider: provider,
      workspaceRoot: workspaceRoot,
    ),
  );
  if (conversation != null && context.mounted) {
    _openConversation(context, session, conversation);
  }
}

void _openConversation(BuildContext context, DeviceSession session, ConversationSummary conversation) {
  Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => ConversationDetailScreen(session: session, conversation: conversation)));
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
