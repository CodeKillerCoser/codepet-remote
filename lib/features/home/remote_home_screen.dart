import 'dart:async';

import 'package:flutter/material.dart';

import '../../devices/device_session.dart';
import '../../gateway/models.dart';
import '../conversations/conversation_detail_screen.dart';

const int _projectPageSize = 6;
const int _conversationPageSize = 8;

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
    if (hasLocalMore) {
      setState(advance);
      return;
    }
    if (!session.canLoadMoreConversations) return;
    await session.loadMoreConversations();
    if (!mounted ||
        session.connectionState != DeviceConnectionState.online ||
        session.loadMoreError != null) {
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
    final projects = session == null ? const <ConversationProject>[] : _sortedProjects(session);
    final recent = session == null
        ? const <ConversationSummary>[]
        : sortRecentConversations(
            deduplicateRoutedConversations(session.conversations),
          );
    final viewState = session == null
        ? null
        : _deviceViewStates.putIfAbsent(
            session.device.deviceId,
            _DeviceHomeViewState.new,
          )
      ?..retainProjects(projects.map((project) => project.key));
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
                  _DeviceActions(session: session),
                  const SizedBox(height: 28),
                  _SectionTitle(
                    key: Key('projects-section-${session.device.deviceId}'),
                    title: '项目',
                    count: projects.length,
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
                    count: recent.length,
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
    );
  }

  List<Widget> _projectWidgets(
    BuildContext context,
    DeviceSession session,
    List<ConversationProject> projects,
    _DeviceHomeViewState viewState,
  ) {
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
    if (projects.isEmpty) {
      return [
        const _MessageCard(
          icon: Icons.folder_off_outlined,
          title: '没有可分组的项目',
          message: '当前会话没有 workspaceRoot；它们仍会显示在“最近”中。',
        ),
        if (session.canLoadMoreConversations ||
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
      final expanded = viewState.expandedProjects[project.key] ?? false;
      final conversationPages =
          viewState.projectConversationPages[project.key] ?? 1;
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _ProjectCard(
          key: Key('project-card-${project.key}'),
          project: project,
          projectName: name,
          expanded: expanded,
          conversationPages: conversationPages,
          onToggle: () => setState(() {
            viewState.expandedProjects[project.key] = !expanded;
          }),
          canLoadMore: session.canLoadMoreConversations,
          isLoadingMore: session.isLoadingMoreConversations,
          loadMoreError: session.loadMoreError,
          onShowMore: () {
            unawaited(_advanceWindow(
              session: session,
              hasLocalMore: conversationPages * _conversationPageSize <
                  project.conversations.length,
              advance: () {
                viewState.projectConversationPages[project.key] =
                    (viewState.projectConversationPages[project.key] ?? 1) + 1;
              },
            ));
          },
          onOpenProject: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) => _ProjectConversationsScreen(
                projectName: name,
                workspaceRoot: project.workspaceRoot,
                session: session,
              ),
            ),
          ),
          onOpenConversation: (conversation) =>
              _openConversation(context, session, conversation),
        ),
      );
    }));
    if (visibleCount < projects.length ||
        session.canLoadMoreConversations ||
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
        if (session.canLoadMoreConversations ||
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
    final requestedCount = viewState.recentPages * _conversationPageSize;
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
            conversation: conversation,
            onTap: () => _openConversation(context, session, conversation),
          ),
        )));
    if (visibleCount < recent.length ||
        session.canLoadMoreConversations ||
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
  final Map<String, bool> expandedProjects = {};
  final Map<String, int> projectConversationPages = {};

  void retainProjects(Iterable<String> values) {
    final keys = values.toSet();
    expandedProjects.removeWhere((key, _) => !keys.contains(key));
    projectConversationPages.removeWhere((key, _) => !keys.contains(key));
  }
}

List<ConversationProject> _sortedProjects(DeviceSession session) {
  final projects = groupConversationsByProject(
    hostDeviceId: session.device.deviceId,
    values: session.conversations,
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
      height: 82,
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
          final deviceDetails = [
            if (alias?.isNotEmpty == true && descriptor != null)
              descriptor.deviceName,
            if (descriptor != null)
              '${descriptor.operatingSystem} ${descriptor.systemVersion}',
            _deviceStateLabel(session.connectionState),
          ].join(' · ');
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
                    Text(
                      alias?.isNotEmpty == true
                          ? alias!
                          : descriptor?.deviceName ?? session.device.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      deviceDetails,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
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
  const _SectionTitle({
    super.key,
    required this.title,
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final String title;
  final int count;
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
              Text('$count', style: Theme.of(context).textTheme.bodySmall),
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
    required this.expanded,
    required this.conversationPages,
    required this.canLoadMore,
    required this.isLoadingMore,
    required this.loadMoreError,
    required this.onToggle,
    required this.onShowMore,
    required this.onOpenProject,
    required this.onOpenConversation,
  });

  final ConversationProject project;
  final String projectName;
  final bool expanded;
  final int conversationPages;
  final bool canLoadMore;
  final bool isLoadingMore;
  final String? loadMoreError;
  final VoidCallback onToggle;
  final VoidCallback onShowMore;
  final VoidCallback onOpenProject;
  final ValueChanged<ConversationSummary> onOpenConversation;

  @override
  Widget build(BuildContext context) {
    final conversations = sortRecentConversations(project.conversations);
    final requestedCount = conversationPages * _conversationPageSize;
    final visibleCount = requestedCount < conversations.length
        ? requestedCount
        : conversations.length;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          ListTile(
            key: Key('project-${project.key}'),
            leading: const Icon(Icons.folder_outlined),
            title: Text(
              projectName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${conversations.length} 个会话 · ${project.workspaceRoot}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  key: Key('open-project-${project.key}'),
                  tooltip: '打开项目会话列表',
                  onPressed: onOpenProject,
                  icon: const Icon(Icons.open_in_new, size: 20),
                ),
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ],
            ),
            onTap: onToggle,
          ),
          if (expanded) ...[
            const Divider(height: 1),
            for (var index = 0; index < visibleCount; index++) ...[
              _ConversationTile(
                key: Key(
                  'project-conversation-${project.key}-${conversationRoutingKey(conversations[index])}',
                ),
                conversation: conversations[index],
                onTap: () => onOpenConversation(conversations[index]),
              ),
              if (index != visibleCount - 1)
                const Divider(height: 1, indent: 56),
            ],
            if (visibleCount < conversations.length ||
                canLoadMore ||
                isLoadingMore)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: _PaginationControl(
                  buttonKey: Key(
                    'show-more-project-conversations-${project.key}',
                  ),
                  label: '显示更多对话',
                  loading: isLoadingMore,
                  error: visibleCount < conversations.length
                      ? null
                      : loadMoreError,
                  onPressed: onShowMore,
                ),
              ),
          ],
        ],
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
    required this.conversation,
    required this.onTap,
  });

  final ConversationSummary conversation;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        child: _ConversationTile(
          key: Key('conversation-${conversation.id}'),
          conversation: conversation,
          onTap: onTap,
        ),
      );
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({
    super.key,
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
    if (!hasLocalMore) {
      if (!widget.session.canLoadMoreConversations) return;
      await widget.session.loadMoreConversations();
      if (!mounted ||
          widget.session.connectionState != DeviceConnectionState.online ||
          widget.session.loadMoreError != null) {
        return;
      }
    }
    setState(() {
      _pages++;
    });
  }

  List<ConversationSummary> _projectConversations() =>
      sortRecentConversations(
        deduplicateRoutedConversations(
          widget.session.conversations.where(
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
        widget.session.canLoadMoreConversations ||
        widget.session.isLoadingMoreConversations;
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
            conversation: conversation,
            onTap: () => _openConversation(
              context,
              widget.session,
              conversation,
            ),
          );
        },
      ),
    );
  }
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
