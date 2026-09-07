import 'dart:async';

import 'recent_conversation_feed.dart';

import 'package:flutter/material.dart';

import '../../application/sessions/device_session.dart';
import '../../core/domain/models.dart';
import '../common/identity_icons.dart';
import '../common/floating_detail_panel.dart';
import '../connection/device_connection_notice.dart';
import '../connection/device_detail_screen.dart';
import '../conversations/conversation_detail_screen.dart';
import '../conversations/conversation_search_screen.dart';
import '../conversations/widgets/conversation_list_item.dart';
export '../conversations/widgets/conversation_list_item.dart' show relativeConversationTime;

const int _projectPageSize = 6;
const int _conversationPageSize = 8;

int _standaloneWorkspaceSequence = 0;

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
  final Set<String> _scheduledProjectConversationCounts = {};

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

  Future<void> _advanceProjectWindow({
    required DeviceSession session,
    required bool hasLocalMore,
    required VoidCallback advance,
  }) async {
    if (session.isLoadingMoreProjects) return;
    if (session.canLoadMoreSelectedProviderProjects) {
      await session.loadMoreSelectedProviderProjects();
      if (!mounted ||
          session.connectionState != DeviceConnectionState.online ||
          session.loadMoreProjectsError != null) {
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
    for (final state in _deviceViewStates.values) {
      state.scrollController.dispose();
    }
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
    final projects = session == null
        ? const <GatewayProject>[]
        : session.selectedProviderProjects;
    final viewState = session == null
        ? _DeviceHomeViewState()
        : _deviceViewStates.putIfAbsent(
            '${session.device.deviceId}\u0000${session.selectedProviderId ?? 'no-provider'}',
            _DeviceHomeViewState.new,
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('CodePet Remote'),
        actions: [
          if (session != null)
            _DeviceDropdown(
              sessions: sessions,
              selectedIndex: selectedIndex,
              onSelect: widget.onSelectDevice,
            ),
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
          : Column(
              key: const Key('remote-home'),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: _DeviceActions(
                    session: session!,
                    selectedProvider: selectedProvider,
                    onSelectProvider: session.selectProvider,
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: ListView(
                    key: const Key('home-content-scroll'),
                    controller: viewState.scrollController,
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                    children: [
                      if (DeviceConnectionNotice.shouldShow(
                        session,
                        includeConnecting: true,
                      )) ...[
                        DeviceConnectionNotice(session: session),
                        const SizedBox(height: 12),
                      ],
                      ...[
                        _SectionTitle(
                          key: Key(
                            'projects-section-${session.device.deviceId}',
                          ),
                          title: '项目',
                          countLabel:
                              '${projects.length + 1}${session.canLoadMoreSelectedProviderProjects ? '+' : ''}',
                          expanded: viewState.projectsExpanded,
                          action:
                              selectedProvider?.isAvailable == true &&
                                  selectedProvider?.methods.contains(
                                        'project.create',
                                      ) ==
                                      true
                              ? IconButton(
                                  key: const Key('project-create'),
                                  tooltip: '新建项目',
                                  onPressed: () => _showProjectEditor(
                                    context,
                                    session: session,
                                    provider: selectedProvider!,
                                  ),
                                  icon: const Icon(
                                    Icons.create_new_folder_outlined,
                                  ),
                                )
                              : null,
                          onTap: () => setState(() {
                            viewState.projectsExpanded =
                                !viewState.projectsExpanded;
                          }),
                        ),
                        if (viewState.projectsExpanded) ...[
                          const SizedBox(height: 10),
                          _ChatProjectCard(session: session),
                          if (session.selectedProviderSupportsProjects)
                            ..._projectWidgets(
                              context,
                              session,
                              projects,
                              viewState,
                            ),
                        ],
                      ],
                      const SizedBox(height: 28),
                      _SectionTitle(
                        key: Key('recent-section-${session.device.deviceId}'),
                        title: '最近',
                        countLabel:
                            session.selectedProviderConversationCountLabel,
                        expanded: viewState.recentExpanded,
                        onTap: () => setState(() {
                          viewState.recentExpanded = !viewState.recentExpanded;
                        }),
                      ),
                      if (viewState.recentExpanded) ...[
                        const SizedBox(height: 10),
                                                RecentConversationFeed(
                          key: ValueKey(viewState),
                          controller: session.selectedProviderRecent,
                          scrollController: viewState.scrollController,
                          online: session.connectionState == DeviceConnectionState.online,
                          onTap: (conversation) => _openConversation(context, session, conversation),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
      bottomNavigationBar: session == null
          ? null
          : _ConversationActionsBar(
              searchKey: const Key('home-search'),
              createKey: const Key('home-new'),
              canSearch: selectedProvider != null,
              canCreate:
                  selectedProvider?.isAvailable == true &&
                  selectedProvider?.methods.contains('conversation.create') ==
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
    List<GatewayProject> projects,
    _DeviceHomeViewState viewState,
  ) {
    if (session.connectionState == DeviceConnectionState.connecting &&
        projects.isEmpty) {
      return const [LinearProgressIndicator()];
    }
    if (session.connectionState != DeviceConnectionState.online) return const [];
    if (projects.isEmpty) {
      return [
        if (session.canLoadMoreSelectedProviderProjects ||
            session.isLoadingMoreProjects)
          _PaginationControl(
            buttonKey: Key(
              'show-more-projects-${session.device.deviceId}',
            ),
            label: '显示更多项目',
            loading: session.isLoadingMoreProjects,
            error: session.loadMoreProjectsError,
            onPressed: () {
              unawaited(session.loadMoreSelectedProviderProjects());
            },
          ),
      ];
    }
    final requestedCount = viewState.projectPages * _projectPageSize;
    final visibleCount = requestedCount < projects.length
        ? requestedCount
        : projects.length;
    _scheduleProjectConversationCounts(
      session,
      projects.take(visibleCount),
    );
    final widgets = <Widget>[];
    widgets.addAll(projects.take(visibleCount).map((project) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _ProjectCard(
            key: Key('project-card-${project.key}'),
            project: project,
            session: session,
            provider: session.selectedProvider!,
            onOpenProject: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => _ProjectConversationsScreen(
                  project: project,
                  session: session,
                ),
              ),
            ),
        ),
      );
    }));
    if (visibleCount < projects.length ||
        session.canLoadMoreSelectedProviderProjects ||
        session.isLoadingMoreProjects) {
      widgets.add(
        _PaginationControl(
          buttonKey: Key('show-more-projects-${session.device.deviceId}'),
          label: '显示更多项目',
          loading: session.isLoadingMoreProjects,
          error:
              visibleCount < projects.length ? null : session.loadMoreProjectsError,
          onPressed: () {
            unawaited(_advanceProjectWindow(
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

  void _scheduleProjectConversationCounts(
    DeviceSession session,
    Iterable<GatewayProject> projects,
  ) {
    for (final project in projects) {
      if (session.hasLoadedProjectConversations(project) ||
          session.isLoadingProjectConversations(project)) {
        continue;
      }
      final key = '${session.device.deviceId}\u0000${project.key}';
      if (!_scheduledProjectConversationCounts.add(key)) continue;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _scheduledProjectConversationCounts.remove(key);
          return;
        }
        unawaited(
          session.ensureProjectConversations(project).whenComplete(() {
            _scheduledProjectConversationCounts.remove(key);
          }),
        );
      });
    }
  }

}

class _DeviceHomeViewState {
  bool projectsExpanded = true;
  bool recentExpanded = true;
  int projectPages = 1;
  final scrollController = ScrollController();
}

class _DeviceDropdown extends StatelessWidget {
  const _DeviceDropdown({
    required this.sessions,
    required this.selectedIndex,
    required this.onSelect,
  });

  final List<DeviceSession> sessions;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = sessions[selectedIndex];
    final colorScheme = Theme.of(context).colorScheme;
    return PopupMenuButton<int>(
      key: const Key('home-device-menu'),
      tooltip: '切换设备',
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (var index = 0; index < sessions.length; index++)
          PopupMenuItem<int>(
            key: Key('device-${sessions[index].device.deviceId}'),
            value: index,
            child: _DeviceMenuItem(
              session: sessions[index],
              selected: index == selectedIndex,
            ),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 132),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DeviceStateIcon(session: selected, size: 28),
              const SizedBox(width: 6),
              Flexible(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.displayDeviceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    Text(
                      _deviceTriggerSubtitle(selected),
                      key: Key(
                        'device-status-${selected.device.deviceId}',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.arrow_drop_down, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}

class _DeviceMenuItem extends StatelessWidget {
  const _DeviceMenuItem({required this.session, required this.selected});

  final DeviceSession session;
  final bool selected;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          _DeviceStateIcon(session: session, size: 32),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session.displayDeviceName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: selected
                      ? const TextStyle(fontWeight: FontWeight.w700)
                      : null,
                ),
                Text(
                  '${session.displaySystemLabel} · ${_deviceMenuStateLabel(session)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (selected) const Icon(Icons.check, size: 18),
        ],
      );
}

class _DeviceStateIcon extends StatelessWidget {
  const _DeviceStateIcon({required this.session, required this.size});

  final DeviceSession session;
  final double size;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: colorScheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(size * 0.28),
          ),
          alignment: Alignment.center,
          child: Icon(
            operatingSystemIconData(session.displaySystemLabel),
            size: size * 0.62,
            color: colorScheme.primary,
          ),
        ),
        Positioned(
          right: -1,
          bottom: -1,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              color: _deviceStateColor(
                colorScheme,
                session.connectionState,
              ),
              shape: BoxShape.circle,
              border: Border.all(color: colorScheme.surface, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

String _deviceMenuStateLabel(DeviceSession session) => session.isReconnecting
    ? '重新连接中'
    : _deviceStateLabel(session.connectionState);

String _deviceTriggerSubtitle(DeviceSession session) =>
    session.connectionState == DeviceConnectionState.online
        ? session.displaySystemLabel
        : _deviceMenuStateLabel(session);

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
                  connectionState: session.connectionState,
                  selected: provider.id == selectedProvider?.id,
                  onSelected: onSelectProvider,
                );
              },
            ),
          ),
          const SizedBox(height: 4),
        ],
        if (selectedProvider != null)
          _ProviderDisclosure(
            key: ValueKey('provider-details-${session.device.deviceId}-${selectedProvider!.id}'),
            provider: selectedProvider!,
            connectionState: session.connectionState,
          )
        else
          Text(handshake == null ? '会话数据仅保留在本次连接中' : '未发现 Provider'),
      ],
    );
  }
}

class _ProviderDisclosure extends StatefulWidget {
  const _ProviderDisclosure({super.key, required this.provider, required this.connectionState});

  final GatewayProvider provider;
  final DeviceConnectionState connectionState;

  @override
  State<_ProviderDisclosure> createState() => _ProviderDisclosureState();
}

class _ProviderDisclosureState extends State<_ProviderDisclosure> {
  final _controller = OverlayPortalController();
  final _link = LayerLink();

  void _toggle() => setState(_controller.toggle);
  void _close() => setState(_controller.hide);

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    return LayoutBuilder(builder: (context, constraints) {
      return CompositedTransformTarget(
        link: _link,
        child: OverlayPortal(
          controller: _controller,
          overlayChildBuilder: (context) => Stack(
            children: [
              Positioned.fill(child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: const SizedBox.expand(),
              )),
              CompositedTransformFollower(
                link: _link,
                showWhenUnlinked: false,
                targetAnchor: Alignment.bottomLeft,
                followerAnchor: Alignment.topLeft,
                offset: const Offset(0, 8),
                child: SizedBox(
                  width: constraints.maxWidth,
                  child: FloatingDetailPanel(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
                        child: ProviderDetails(provider: provider),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          child: InkWell(
            onTap: _toggle,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(children: [
                Expanded(child: Text(
                  '${provider.displayName} · ${provider.runtimeVersion == null ? '版本未提供' : 'v${provider.runtimeVersion}'} · ${_providerStateLabel(provider, widget.connectionState)}',
                  style: Theme.of(context).textTheme.bodySmall,
                )),
                AnimatedRotation(
                  turns: _controller.isShowing ? 0.5 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: Icon(Icons.expand_more, size: 20,
                    semanticLabel: _controller.isShowing ? '收起 Provider 信息' : '展开 Provider 信息'),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}

class _ProviderIdentity extends StatelessWidget {
  const _ProviderIdentity({
    required this.provider,
    required this.connectionState,
    required this.selected,
    required this.onSelected,
  });

  final GatewayProvider provider;
  final DeviceConnectionState connectionState;
  final bool selected;
  final ValueChanged<GatewayProvider> onSelected;

  @override
  Widget build(BuildContext context) {
    final ready = provider.isAvailable;
    return ChoiceChip(
      key: Key('provider-${provider.id}'),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(provider),
      visualDensity: VisualDensity.compact,
      avatar: ProviderIcon(
        icon: provider.icon,
        providerIdentity: provider.id,
        size: 17,
        color: ready
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.outline,
        semanticLabel: '${provider.displayName} Provider',
      ),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(provider.displayName),
          const SizedBox(width: 8),
          Semantics(
            label: _providerStateLabel(provider, connectionState),
            child: Container(
              key: Key('provider-status-${provider.id}'),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: switch (_providerStateLabel(provider, connectionState)) {
                  '在线' => Colors.green.shade600,
                  '连接中' => Colors.amber.shade600,
                  _ => Colors.red.shade600,
                },
              ),
            ),
          ),
        ],
      ),
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
    this.action,
  });

  final String title;
  final String countLabel;
  final bool expanded;
  final VoidCallback onTap;
  final Widget? action;

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
          ?action,
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
    required this.session,
    required this.provider,
    required this.onOpenProject,
  });

  final GatewayProject project;
  final DeviceSession session;
  final GatewayProvider provider;
  final VoidCallback onOpenProject;

  @override
  Widget build(BuildContext context) {
    final roots = project.roots.map((root) => root.path).join(' · ');
    final conversationCount = session.projectConversationCountLabel(project);
    final conversations = session.conversationsForProject(project);
    final canUpdate = provider.isAvailable &&
        provider.methods.contains('project.update');
    final canDelete = provider.isAvailable &&
        provider.methods.contains('project.delete');
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('project-${project.key}'),
        onTap: onOpenProject,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.folder_outlined, size: 20),
                      const SizedBox(width: 8),
                      Flexible(child: Text(project.name, maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium)),
                      const SizedBox(width: 8),
                      Text(conversationCount ?? '…',
                        key: Key('project-conversation-count-${project.key}'),
                        style: Theme.of(context).textTheme.bodySmall),
                      ConversationIndicators(
                        running: conversations.any(
                          (item) => item.status == ConversationStatus.running),
                        unread: conversations.any(
                          (item) => item.readState.unread),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    HeadTailPath(roots.isEmpty ? '未关联目录' : roots),
                  ],
                ),
              ),
              if (canUpdate || canDelete)
                PopupMenuButton<String>(
                  key: Key('project-menu-${project.key}'),
                  onSelected: (value) {
                    if (value == 'edit') {
                      unawaited(_showProjectEditor(
                        context,
                        session: session,
                        provider: provider,
                        project: project,
                      ));
                    }
                    if (value == 'delete') {
                      unawaited(_confirmDeleteProject(
                        context,
                        session: session,
                        provider: provider,
                        project: project,
                      ));
                    }
                  },
                  itemBuilder: (_) => [
                    if (canUpdate)
                      const PopupMenuItem(value: 'edit', child: Text('编辑项目')),
                    if (canDelete)
                      const PopupMenuItem(value: 'delete', child: Text('删除项目')),
                  ],
                )
            ],
          ),
        ),
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
  const _MessageCard({required this.icon, required this.title, required this.message});
  final IconData icon;
  final String title;
  final String message;
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
        ])),
      ]),
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

class _ChatProjectCard extends StatelessWidget {
  const _ChatProjectCard({required this.session});

  final DeviceSession session;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Card(
      key: const Key('chat-project-card'),
      margin: EdgeInsets.zero,
      elevation: 0,
      child: ListTile(
        leading: const Icon(Icons.forum_outlined),
        title: const Text('聊天'),
        subtitle: const Text('无项目归属的对话'),
        trailing: Text(
          '${session.selectedProviderStandaloneConversations.length}${session.canLoadMoreSelectedProviderConversations ? '+' : ''}',
        ),
        onTap: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => _ProjectConversationsScreen(session: session),
          ),
        ),
      ),
    ),
  );
}

class _ProjectConversationsScreen extends StatefulWidget {
  const _ProjectConversationsScreen({this.project, required this.session});

  final GatewayProject? project;
  final DeviceSession session;

  @override
  State<_ProjectConversationsScreen> createState() =>
      _ProjectConversationsScreenState();
}

class _ProjectConversationsScreenState
    extends State<_ProjectConversationsScreen> {
  int _pages = 1;

  GatewayProject? get _project {
    for (final project in widget.session.selectedProviderProjects) {
      if (project.resource == widget.project?.resource) return project;
    }
    return widget.project;
  }

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.project != null) {
        unawaited(widget.session.ensureProjectConversations(widget.project!));
      }
    });
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
    if (_canLoadMore) {
      if (widget.project == null) {
        await widget.session.loadMoreSelectedProviderConversations();
      } else {
        await widget.session.loadMoreProjectConversations(widget.project!);
      }
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

  bool get _canLoadMore => _project == null
      ? widget.session.canLoadMoreSelectedProviderConversations
      : widget.session.canLoadMoreProjectConversations(_project!);

  List<ConversationSummary> _projectConversations() => _project == null
      ? sortRecentConversations(
          widget.session.selectedProviderStandaloneConversations,
        )
      : widget.session.conversationsForProject(_project!);

  @override
  Widget build(BuildContext context) {
    final conversations = _projectConversations();
    final requestedCount = _pages * _conversationPageSize;
    final visibleCount = requestedCount < conversations.length
        ? requestedCount
        : conversations.length;
    final hasLocalMore = visibleCount < conversations.length;
    final hasMore =
        hasLocalMore ||
        _canLoadMore ||
        widget.session.isLoadingMoreConversations;
    final selectedProvider = widget.session.selectedProvider;
    return Scaffold(
      appBar: AppBar(
        leadingWidth: 48,
        titleSpacing: 0,
        toolbarHeight: 64,
        title: _project == null
            ? const Text('聊天')
            : _ProjectConversationTitle(
                project: _project!,
                session: widget.session,
                provider: selectedProvider,
              ),
      ),
      body: ConversationList(
        key: const Key('project-conversation-list'),
        conversations: conversations.take(visibleCount).toList(growable: false),
        itemKey: (conversation) => Key('project-screen-conversation-${conversationRoutingKey(conversation)}'),
        onTap: (current) => _openConversation(context, widget.session, current),
        leading: [
          if (conversations.isEmpty && !hasMore)
            const _MessageCard(icon: Icons.forum_outlined, title: '还没有会话', message: '点击新建开始聊天。'),
        ],
        trailing: [
          if (hasMore) _PaginationControl(
            buttonKey: const Key('show-more-project-screen-conversations'),
            label: '显示更多对话',
            loading: widget.session.isLoadingMoreConversations,
            error: hasLocalMore ? null : widget.session.loadMoreError,
            onPressed: () => unawaited(_showMore(hasLocalMore: hasLocalMore)),
          ),
        ],
      ),
      bottomNavigationBar: _ConversationActionsBar(
        searchKey: const Key('project-search'),
        createKey: const Key('project-new'),
        canSearch: selectedProvider != null,
        canCreate:
            selectedProvider?.isAvailable == true &&
            selectedProvider?.methods.contains('conversation.create') == true,
        onSearch: () =>
            _openSearch(context, widget.session, project: _project?.resource, standaloneOnly: _project == null),
        onCreate: selectedProvider == null
            ? null
            : () => _startConversation(
                context,
                session: widget.session,
                provider: selectedProvider,
                project: _project,
              ),
      ),
    );
  }
}

class _ProjectConversationTitle extends StatelessWidget {
  const _ProjectConversationTitle({
    required this.project,
    required this.session,
    required this.provider,
  });

  final GatewayProject project;
  final DeviceSession session;
  final GatewayProvider? provider;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          ProviderIcon(
            key: const Key('project-provider-icon'),
            icon: provider?.icon,
            providerIdentity: provider?.id ?? project.resource.providerId,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: provider?.displayName ?? 'Provider',
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  project.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  '${session.displayDeviceName} · ${session.displaySystemLabel}',
                  key: const Key('project-device-context'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                ),
              ],
            ),
          ),
        ],
      );
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

class _ProjectEditorDialog extends StatefulWidget {
  const _ProjectEditorDialog({
    required this.session,
    required this.provider,
    this.project,
  });

  final DeviceSession session;
  final GatewayProvider provider;
  final GatewayProject? project;

  @override
  State<_ProjectEditorDialog> createState() => _ProjectEditorDialogState();
}

class _ProjectEditorDialogState extends State<_ProjectEditorDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _rootsController;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.project?.name);
    _rootsController = TextEditingController(
      text: widget.project?.roots.map((root) => root.path).join('\n'),
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _rootsController.dispose();
    super.dispose();
  }

  List<ProjectRoot> get _roots => _rootsController.text
      .split('\n')
      .map((path) => path.trim())
      .where((path) => path.isNotEmpty)
      .map((path) => ProjectRoot(path: path))
      .toList(growable: false);

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final current = widget.project;
      final result = current == null
          ? await widget.session.createProject(
              provider: widget.provider,
              name: _nameController.text,
              roots: _roots,
            )
          : await widget.session.updateProject(
              provider: widget.provider,
              project: current,
              name: _nameController.text,
              roots: _roots,
            );
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.project == null ? '新建项目' : '编辑项目'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('project-name'),
                controller: _nameController,
                enabled: !_saving,
                decoration: const InputDecoration(labelText: '项目名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const Key('project-roots'),
                controller: _rootsController,
                enabled: !_saving,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '目录（每行一个，可留空）',
                  prefixIcon: Icon(Icons.folder_outlined),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('confirm-project-save'),
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      );
}

class _NewConversationDialog extends StatefulWidget {
  const _NewConversationDialog({
    required this.session,
    required this.provider,
    this.workspaceRoot,
    this.project,
  });

  final DeviceSession session;
  final GatewayProvider provider;
  final String? workspaceRoot;
  final GatewayProject? project;

  @override
  State<_NewConversationDialog> createState() =>
      _NewConversationDialogState();
}

class _NewConversationDialogState extends State<_NewConversationDialog> {
  static const _standaloneProjectKey = '';

  late final TextEditingController _titleController;
  late final TextEditingController _workspaceController;
  late String _selectedProjectKey;
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

  bool get _supportsProjects =>
      widget.provider.methods.contains('project.list');

  List<GatewayProject> get _projects => widget.session.projects
      .where((project) => project.resource.providerId == widget.provider.id)
      .toList(growable: false);

  GatewayProject? get _selectedProject {
    if (_selectedProjectKey == _standaloneProjectKey) return null;
    for (final project in _projects) {
      if (project.key == _selectedProjectKey) return project;
    }
    return widget.project;
  }

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController();
    _workspaceController = TextEditingController(
      text: widget.workspaceRoot ??
          _newStandaloneWorkspace(widget.provider.defaultWorkspaceRoot),
    );
    _selectedProjectKey = widget.project?.key ?? _standaloneProjectKey;
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
    final project = _selectedProject;
    if (project == null && _workspaceController.text.trim().isEmpty) {
      setState(() {
        _error = '无项目会话需要填写工作区路径';
      });
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final conversation = await widget.session.createConversation(
        provider: widget.provider,
        title: _titleController.text,
        workspaceRoot: project == null ? _workspaceController.text : null,
        permissionLevel: _permissionLevel,
        reasoningEffort: _reasoningEffort,
        model: _model,
        workspaceMode: _workspaceMode,
        project: project,
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
              if (_supportsProjects) ...[
                DropdownButtonFormField<String>(
                  key: const Key('new-conversation-project'),
                  initialValue: _selectedProjectKey,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '项目',
                    prefixIcon: Icon(Icons.folder_copy_outlined),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: _standaloneProjectKey,
                      child: Text('聊天'),
                    ),
                    for (final project in _projects)
                      DropdownMenuItem(
                        value: project.key,
                        child: Text(
                          project.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _creating
                      ? null
                      : (value) => setState(() {
                            _selectedProjectKey =
                                value ?? _standaloneProjectKey;
                            _error = null;
                          }),
                ),
                const SizedBox(height: 12),
              ],
              if (_selectedProject == null)
                TextField(
                  key: const Key('new-conversation-workspace'),
                  controller: _workspaceController,
                  enabled: !_creating,
                  decoration: const InputDecoration(
                    labelText: '工作区路径',
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

Future<void> _showProjectEditor(
  BuildContext context, {
  required DeviceSession session,
  required GatewayProvider provider,
  GatewayProject? project,
}) => showDialog<GatewayProject>(
  context: context,
  builder: (_) => _ProjectEditorDialog(
    session: session,
    provider: provider,
    project: project,
  ),
);

Future<void> _confirmDeleteProject(
  BuildContext context, {
  required DeviceSession session,
  required GatewayProvider provider,
  required GatewayProject project,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('删除项目？'),
      content: Text('将删除“${project.name}”的项目记录，不会删除目录中的文件。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm-project-delete'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  await session.deleteProject(provider: provider, project: project);
}

void _openSearch(
  BuildContext context,
  DeviceSession session, {
  RoutedResourceId? project,
  bool standaloneOnly = false,
}) {
  Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) =>
          ConversationSearchScreen(session: session, project: project, standaloneOnly: standaloneOnly),
    ),
  );
}

Future<void> _startConversation(
  BuildContext context, {
  required DeviceSession session,
  required GatewayProvider provider,
  String? workspaceRoot,
  GatewayProject? project,
}) async {
  final conversation = await showDialog<ConversationSummary>(
    context: context,
    builder: (_) => _NewConversationDialog(
      session: session,
      provider: provider,
      workspaceRoot: workspaceRoot,
      project: project,
    ),
  );
  if (conversation != null && context.mounted) {
    _openConversation(context, session, conversation);
  }
}

String? _newStandaloneWorkspace(String? parent) {
  final trimmed = parent?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  final separator = trimmed.contains('\\') && !trimmed.contains('/') ? '\\' : '/';
  final needsSeparator = !trimmed.endsWith('/') && !trimmed.endsWith('\\');
  final sequence = _standaloneWorkspaceSequence++;
  final taskName =
      '${DateTime.now().toUtc().microsecondsSinceEpoch}-$sequence';
  return '$trimmed${needsSeparator ? separator : ''}task$separator$taskName';
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

String _providerStateLabel(GatewayProvider provider, DeviceConnectionState state) {
  if (state == DeviceConnectionState.connecting) return '连接中';
  if (state != DeviceConnectionState.online || provider.connectionStatus == 'offline') {
    return '不可用';
  }
  if (provider.connectionStatus == 'connecting' || provider.status == ProviderStatus.connecting) {
    return '连接中';
  }
  return provider.isAvailable ? '在线' : '不可用';
}
