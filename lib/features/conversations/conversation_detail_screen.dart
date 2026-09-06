import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/conversations/conversation_detail_controller.dart';
import '../../application/conversations/conversation_timeline.dart';
import '../../application/sessions/device_session.dart';
import '../../core/domain/models.dart';
import '../common/identity_icons.dart';
import '../common/floating_detail_panel.dart';
import '../connection/device_connection_notice.dart';
import 'widgets/conversation_timeline_view.dart';

const int _messagePageSize = 40;
const double _nearBottomThreshold = 160;
const ConversationTimelineProjector _timelineProjector =
    ConversationTimelineProjector();

class ConversationDetailScreen extends StatefulWidget {
  const ConversationDetailScreen({
    super.key,
    required this.session,
    required this.conversation,
  });

  final DeviceSession session;
  final ConversationSummary conversation;

  @override
  State<ConversationDetailScreen> createState() =>
      _ConversationDetailScreenState();
}

class _ConversationDetailScreenState extends State<ConversationDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _messagesCenterKey = GlobalKey();
  final TextEditingController _draftController = TextEditingController();
  late ConversationDetailController _controller;
  List<ConversationTimelineBlock> _timeline = const [];
  bool _metadataExpanded = false;
  int _hiddenMessageCount = 0;
  String? _centerBlockId;
  bool _showScrollToBottom = false;
  int _scrollRequest = 0;
  bool _followOutput = true;
  bool _userScrolling = false;

  GatewayProvider? get _provider => _controller.provider;
  ConversationDetail? get _detail => _controller.detail;
  String? get _error => _controller.error;
  String? get _sendError => _controller.sendError;
  String? get _interactionError => _controller.interactionError;
  String? get _accessModeId => _controller.accessModeId;
  String? get _reasoningEffortId => _controller.reasoningEffortId;
  ModelSelection? get _modelSelection => _controller.modelSelection;
  bool get _sending => _controller.sending;
  bool get _outcomeUnknown => _controller.outcomeUnknown;
  GatewayMessage? get _pendingApproval => _controller.pendingApproval;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _draftController.addListener(_draftChanged);
    _controller = ConversationDetailController(
      session: widget.session,
      conversation: widget.conversation,
    )..addListener(_controllerChanged);
    unawaited(_controller.reload());
  }

  @override
  void didUpdateWidget(ConversationDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session &&
        conversationRoutingKey(oldWidget.conversation) ==
            conversationRoutingKey(widget.conversation)) {
      return;
    }
    _followOutput = true;
    _userScrolling = false;
    _scrollRequest++;
    _timeline = const [];
    _centerBlockId = null;
    _hiddenMessageCount = 0;
    _controller
      ..removeListener(_controllerChanged)
      ..dispose();
    _controller = ConversationDetailController(
      session: widget.session,
      conversation: widget.conversation,
    )..addListener(_controllerChanged);
    unawaited(_controller.reload());
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_controllerChanged)
      ..dispose();
    _draftController.removeListener(_draftChanged);
    _draftController.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _draftChanged() {
    if (mounted) setState(() {});
  }

  void _controllerChanged() {
    if (!mounted) return;
    final renderTrace = _controller.consumePendingRenderTrace();
    final projectionStopwatch = renderTrace == null ? null : (Stopwatch()..start());
    final wasNearBottom = _isNearBottom();
    final previousWasEmpty = _timeline.isEmpty;
    final detail = _controller.detail;
    final firstDetail = previousWasEmpty && detail != null;
    final nextTimeline = detail == null
        ? const <ConversationTimelineBlock>[]
        : _timelineProjector.projectForDisplay(detail);
    if (renderTrace case (final context, final eventCursor, final turnId)) {
      widget.session.traceRecorder.instant(
        'mobile.timeline.projected',
        context: context,
        attributes: {
          'event.cursor': eventCursor,
          'turn.id': turnId,
          'durationUs': projectionStopwatch!.elapsedMicroseconds,
          'timeline.blocks': nextTimeline.length,
        },
      );
    }
    final followOutput = _controller.consumeFollowOutputRequest();
    setState(() {
      _timeline = nextTimeline;
      if (previousWasEmpty && detail != null) {
        _hiddenMessageCount = nextTimeline.length > _messagePageSize
            ? nextTimeline.length - _messagePageSize
            : 0;
      } else {
        _convergeHiddenMessageCount(nextTimeline.length);
      }
      if (detail == null) {
        _showScrollToBottom = false;
        _scrollRequest++;
      }
    });
    if (renderTrace case (final context, final eventCursor, final turnId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        widget.session.traceRecorder.instant(
          'mobile.first_output.rendered',
          context: context,
          attributes: {
            'event.cursor': eventCursor,
            'turn.id': turnId,
          },
        );
      });
    }
    if (firstDetail) {
      _scrollToBottom();
    } else if (followOutput && wasNearBottom && _followOutput && !_userScrolling) {
      _followStreamingOutput();
    } else {
      _scheduleScrollStateUpdate();
    }
  }

  Future<void> _bindRuntime() => _controller.reload(forceRefresh: true);

  bool get _canSend => _controller.canSend(_draftController.text);

  bool get _composerEnabled => _controller.composerEnabled;

  Future<void> _send() async {
    final sent = await _controller.send(_draftController.text);
    if (!mounted || !sent) return;
    _draftController.clear();
    _scrollToBottom();
  }

  void _clearUnknownOutcome() => _controller.clearUnknownOutcome();
  Future<void> _interrupt() => _controller.interrupt();
  Future<void> _resolveApproval(ApprovalDecision decision) =>
      _controller.resolveApproval(decision);
  void _convergeHiddenMessageCount(int messageCount) {
    if (_hiddenMessageCount <= messageCount) return;
    _hiddenMessageCount = messageCount > _messagePageSize
        ? messageCount - _messagePageSize
        : 0;
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    return _scrollController.position.extentAfter <= _nearBottomThreshold;
  }

  void _handleScroll() {
    if (!mounted) return;
    final shouldShow = _scrollController.hasClients &&
        (!_isNearBottom() || !_followOutput);
    if (shouldShow == _showScrollToBottom) return;
    setState(() {
      _showScrollToBottom = shouldShow;
    });
  }

  void _scheduleScrollStateUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleScroll();
    });
  }

  void _followStreamingOutput() {
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _scrollRequest ||
          !_followOutput ||
          _userScrolling ||
          !_scrollController.hasClients) {
        return;
      }
      _scrollController.jumpTo(
        _scrollController.position.maxScrollExtent,
      );
      _handleScroll();
    });
  }

  void _scrollToBottom() {
    _followOutput = true;
    _userScrolling = false;
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _scrollRequest ||
          !_followOutput ||
          _userScrolling ||
          !_scrollController.hasClients) {
        return;
      }
      unawaited(
        _scrollController
            .animateTo(
              _scrollController.position.maxScrollExtent,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            )
            .then((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted ||
                request != _scrollRequest ||
                !_scrollController.hasClients) {
              return;
            }
            _scrollController.jumpTo(
              _scrollController.position.maxScrollExtent,
            );
          });
        }),
      );
    });
  }

  void _showEarlierMessages() {
    if (_hiddenMessageCount == 0) {
      unawaited(_controller.loadEarlier());
      return;
    }
    _scrollRequest++;
    setState(() {
      _hiddenMessageCount = _hiddenMessageCount > _messagePageSize
          ? _hiddenMessageCount - _messagePageSize
          : 0;
    });
    _scheduleScrollStateUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider ??
        widget.session.providerForConversation(
          _detail?.summary ?? widget.conversation,
        );
    final providerIdentity = provider?.id ??
        widget.conversation.providerId;
    final summary = _detail?.summary ?? widget.conversation;
    final detailStatus = _detail?.effectiveStatus ?? summary.status;
    final displayStatus = detailStatus == ConversationStatus.idle &&
            _timeline.any((block) => block.isRunning)
        ? ConversationStatus.running
        : detailStatus;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leadingWidth: 48,
        titleSpacing: 0,
        toolbarHeight: 64,
        title: _ConversationTitle(
          summary: summary,
          status: displayStatus,
          session: widget.session,
          expanded: _metadataExpanded,
          onTap: () => setState(() {
            _metadataExpanded = !_metadataExpanded;
          }),
          providerIcon: ProviderIcon(
            key: const Key('conversation-provider-icon'),
            icon: provider?.icon,
            providerIdentity: providerIdentity,
            size: 22,
            color: Theme.of(context).colorScheme.primary,
            semanticLabel: provider?.displayName ?? 'Provider',
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: _buildBody()),
          if (_detail != null &&
              DeviceConnectionNotice.shouldShow(
                widget.session,
                includeConnecting: true,
              ))
            Positioned(
              top: 8,
              left: 12,
              right: 12,
              child: DeviceConnectionNotice(session: widget.session),
            )
          else if (_error != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: MaterialBanner(
                content: Text(
                  _error!,
                  key: const Key('conversation-history-error'),
                ),
                actions: [
                  TextButton(
                    onPressed: () => unawaited(_bindRuntime()),
                    child: const Text('重新加载'),
                  ),
                ],
              ),
            ),
          Positioned(
            top: 8,
            left: 12,
            right: 12,
            child: IgnorePointer(
              ignoring: !_metadataExpanded,
              child: AnimatedSwitcher(
                key: const Key('conversation-title-metadata-animation'),
                duration: const Duration(milliseconds: 220),
                reverseDuration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, animation) {
                  final curvedAnimation = CurvedAnimation(
                    parent: animation,
                    curve: Curves.easeOutCubic,
                    reverseCurve: Curves.easeInCubic,
                  );
                  return FadeTransition(
                    opacity: curvedAnimation,
                    child: SizeTransition(
                      sizeFactor: curvedAnimation,
                      alignment: Alignment.topCenter,
                      child: child,
                    ),
                  );
                },
                child: _metadataExpanded
                    ? _ConversationMetadataPanel(
                        key: const Key('conversation-title-metadata'),
                        summary: summary,
                      )
                    : const SizedBox.shrink(
                        key: Key('conversation-title-metadata-collapsed'),
                      ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: AnimatedPadding(
        key: const Key('keyboard-aware-composer'),
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: keyboardInset),
        child: _buildComposer(),
      ),
      floatingActionButton: _showScrollToBottom
          ? FloatingActionButton.small(
              key: const Key('scroll-to-bottom'),
              tooltip: '回到底部',
              onPressed: _scrollToBottom,
              child: const Icon(Icons.arrow_downward),
            )
          : null,
    );
  }

  Widget _buildBody() {
    final detail = _detail;
    if (detail == null && _error == null) {
      if (DeviceConnectionNotice.shouldShow(
        widget.session,
        includeConnecting: true,
      )) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: DeviceConnectionNotice(session: widget.session),
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    if (detail == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => unawaited(_bindRuntime()),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final timeline = _timeline;
    var centerBlockIndex = _centerBlockId == null
        ? -1 : timeline.indexWhere((block) => block.id == _centerBlockId);
    if (centerBlockIndex < 0) {
      centerBlockIndex = timeline.length > _messagePageSize
          ? timeline.length - _messagePageSize : 0;
      if (timeline.isNotEmpty) _centerBlockId = timeline[centerBlockIndex].id;
    }
    final centerBlockCount = timeline.length - centerBlockIndex;
    final earlierVisibleBlockCount =
        centerBlockIndex - _hiddenMessageCount;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.depth != 0) return false;
        if (notification is ScrollStartNotification &&
            notification.dragDetails != null) {
          _userScrolling = true;
          _followOutput = false;
          _scrollRequest++;
          _handleScroll();
        } else if (notification is ScrollEndNotification && _userScrolling) {
          _userScrolling = false;
          // Resume only when the user actually returns to the bottom.
          _followOutput = notification.metrics.extentAfter <= 1;
          _handleScroll();
        }
        return false;
      },
      child: CustomScrollView(
        key: const Key('conversation-detail'),
        controller: _scrollController,
        center: _messagesCenterKey,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverList(
              delegate: SliverChildListDelegate.fixed([
                if (_hiddenMessageCount > 0 || _controller.hasEarlier) ...[
                  Center(
                    child: TextButton.icon(
                      key: const Key('show-earlier-messages'),
                      onPressed: _controller.loadingEarlier ? null : _showEarlierMessages,
                      icon: const Icon(Icons.expand_less),
                      label: Text(_controller.loadingEarlier ? '正在加载更早消息…' : '显示更早消息'),
                    ),
                  ),
                  if (_controller.historyError != null)
                    Text(_controller.historyError!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                ],
              ]),
            ),
          ),
          if (earlierVisibleBlockCount > 0)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              sliver: SliverList(
                delegate: SliverChildListDelegate.fixed([
                  for (var index = 0;
                      index < earlierVisibleBlockCount;
                      index++)
                    Builder(builder: (context) {
                      final block = timeline[centerBlockIndex - index - 1];
                      return Padding(
                        key: Key('message-${block.id}'),
                        padding: const EdgeInsets.only(bottom: 10),
                        child: ConversationTimelineBlockView(
                          key: ValueKey(block.id),
                          block: block,
                          allowCopy: _detail?.activeTurn?.id != block.turnId &&
                            _detail?.effectiveStatus != ConversationStatus.running,
                        ),
                      );
                    }),
                ]),
              ),
            ),
          SliverPadding(
            key: _messagesCenterKey,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 28),
            sliver: timeline.isEmpty
                ? const SliverToBoxAdapter(child: _NoHistoryNotice())
                : SliverList(
                        // The latest page is deliberately bounded and fixed so
                        // scrolling to the bottom uses an exact max extent.
                        delegate: SliverChildListDelegate.fixed([
                          for (var index = 0;
                              index < centerBlockCount;
                              index++)
                            Builder(builder: (context) {
                              final block =
                                  timeline[centerBlockIndex + index];
                              return Padding(
                                key: Key('message-${block.id}'),
                                padding: EdgeInsets.only(
                                  bottom: index == centerBlockCount - 1
                                      ? 0
                                      : 10,
                                ),
                                child: ConversationTimelineBlockView(
                                  key: ValueKey(block.id),
                                  block: block,
                          allowCopy: _detail?.activeTurn?.id != block.turnId &&
                            _detail?.effectiveStatus != ConversationStatus.running,
                                ),
                              );
                            }),
                        ]),
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildComposer() {
    final interactionError = _interactionError;
    if (interactionError != null) {
      return Material(
        key: const Key('interaction-unavailable'),
        elevation: 8,
        color: Theme.of(context).colorScheme.surface,
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.edit_off_outlined,
                  size: 20,
                  color: Theme.of(context).colorScheme.error,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    interactionError,
                    key: const Key('interaction-error'),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.error,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }
    final capabilities = _provider?.capabilities.turnSend;
    final selectorEnabled = _composerEnabled;
    return Material(
      key: const Key('conversation-composer'),
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_detail != null && _timelineProjector.fileChanges(_detail!).count > 0)
                FileChangeSummaryView(summary: _timelineProjector.fileChanges(_detail!)),
              if (_pendingApproval != null) ...[
                _ApprovalActions(
                  approval: _pendingApproval!,
                  resolving: _controller.resolvingApprovalId != null,
                  canApprove: _controller.canResolveApproval(ApprovalDecision.approve),
                  canDeny: _controller.canResolveApproval(ApprovalDecision.deny),
                  onApprove: () => unawaited(_resolveApproval(ApprovalDecision.approve)),
                  onDeny: () => unawaited(_resolveApproval(ApprovalDecision.deny)),
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                key: const Key('turn-input'),
                controller: _draftController,
                enabled: _composerEnabled,
                minLines: 2,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: _composerHint,
                  border: InputBorder.none,
                  isDense: true,
                ),
              ),
              if (_sendError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _sendError!,
                  key: const Key('turn-send-error'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
                if (_outcomeUnknown)
                  Wrap(
                    alignment: WrapAlignment.end,
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        key: const Key('turn-unknown-refresh'),
                        onPressed: widget.session.runtimeLease == null
                            ? null
                            : () => unawaited(_bindRuntime()),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('刷新会话核对'),
                      ),
                      TextButton(
                        key: const Key('turn-unknown-dismiss'),
                        onPressed: _clearUnknownOutcome,
                        child: const Text('已核对，继续编辑'),
                      ),
                    ],
                  ),
              ],
              if (_controller.controlError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _controller.controlError!,
                  key: const Key('conversation-control-error'),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                ),
              ],
              const SizedBox(height: 6),
              Row(
                key: const Key('composer-toolbar'),
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      key: const Key('composer-options-scroll'),
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          if (capabilities?.accessMode != null)
                            _ChoiceSelector(
                              key: const Key('access-mode-selector'),
                              icon: Icons.shield_outlined,
                              labelPrefix: '访问',
                              choices: capabilities!.accessMode!,
                              selectedId: _accessModeId,
                              enabled: selectorEnabled,
                              onSelected: (value) {
                                _controller.selectAccessMode(value);
                              },
                            ),
                          if (capabilities?.accessMode != null &&
                              capabilities?.reasoningEffort != null)
                            const SizedBox(width: 4),
                          if (capabilities?.reasoningEffort != null)
                            _ChoiceSelector(
                              key: const Key('reasoning-effort-selector'),
                              icon: Icons.psychology_outlined,
                              labelPrefix: '推理',
                              choices: capabilities!.reasoningEffort!,
                              selectedId: _reasoningEffortId,
                              enabled: selectorEnabled,
                              onSelected: (value) {
                                _controller.selectReasoningEffort(value);
                              },
                            ),
                          if ((capabilities?.accessMode != null ||
                                  capabilities?.reasoningEffort != null) &&
                              capabilities?.modelCatalog != null)
                            const SizedBox(width: 4),
                          if (capabilities?.modelCatalog != null)
                            _ModelSelector(
                              key: const Key('model-selector'),
                              catalog: capabilities!.modelCatalog!,
                              selected: _modelSelection,
                              enabled: selectorEnabled,
                              onSelected: (value) {
                                _controller.selectModel(value);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_controller.canInterrupt || _controller.interrupting)
                    IconButton.filled(
                      key: const Key('turn-interrupt'),
                      tooltip: '停止任务',
                      onPressed: _controller.canInterrupt ? () => unawaited(_interrupt()) : null,
                      icon: _controller.interrupting
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.stop_rounded),
                    )
                  else
                    IconButton.filled(
                      key: const Key('turn-send'),
                      tooltip: '发送',
                      onPressed: _canSend ? () => unawaited(_send()) : null,
                      icon: _sending
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.arrow_upward),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _composerHint => _controller.composerHint;
}

class _ApprovalActions extends StatelessWidget {
  const _ApprovalActions({required this.approval, required this.resolving,
    required this.canApprove, required this.canDeny,
    required this.onApprove, required this.onDeny});

  final GatewayMessage approval;
  final bool resolving;
  final bool canApprove;
  final bool canDeny;
  final VoidCallback onApprove;
  final VoidCallback onDeny;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(approval.title ?? '需要审批', key: const Key('pending-approval-title'),
              style: Theme.of(context).textTheme.titleSmall),
            if (approval.approvalDescription?.isNotEmpty == true) ...[
              const SizedBox(height: 2),
              Text(approval.approvalDescription!,
                key: const Key('pending-approval-description'),
                maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (resolving)
                  const Padding(padding: EdgeInsets.only(right: 12),
                    child: SizedBox.square(dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))),
                TextButton(key: const Key('approval-deny'),
                  onPressed: canDeny ? onDeny : null, child: const Text('拒绝')),
                const SizedBox(width: 4),
                FilledButton(key: const Key('approval-approve'),
                  onPressed: canApprove ? onApprove : null, child: const Text('批准')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationTitle extends StatelessWidget {
  const _ConversationTitle({
    required this.summary,
    required this.status,
    required this.session,
    required this.providerIcon,
    required this.expanded,
    required this.onTap,
  });

  final ConversationSummary summary;
  final ConversationStatus status;
  final DeviceSession session;
  final Widget providerIcon;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final statusColor = switch (status) {
      ConversationStatus.running => Colors.green,
      ConversationStatus.waitingApproval => colorScheme.tertiary,
      ConversationStatus.waitingUserInput => colorScheme.primary,
      ConversationStatus.error => colorScheme.error,
      ConversationStatus.idle || ConversationStatus.archived =>
        colorScheme.outline,
    };
    return InkWell(
      key: const Key('conversation-title-metadata-toggle'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Row(
        children: [
          providerIcon,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Row(
                  key: const Key('conversation-title-status'),
                  children: [
                    Expanded(
                      child: Text(
                        '${session.displayDeviceName} · ${session.displaySystemLabel}',
                        key: const Key('conversation-device-context'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context)
                            .textTheme
                            .labelSmall
                            ?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      _statusLabel(status),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          AnimatedRotation(
            key: const Key('conversation-title-metadata-arrow'),
            turns: expanded ? 0.5 : 0,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            child: Icon(
              Icons.expand_more,
              size: 20,
              semanticLabel: expanded ? '收起会话信息' : '展开会话信息',
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _ConversationMetadataPanel extends StatelessWidget {
  const _ConversationMetadataPanel({
    super.key,
    required this.summary,
  });

  final ConversationSummary summary;

  bool get _hasPreview =>
      summary.preview != null && summary.preview!.isNotEmpty;
  bool get _hasModel =>
      summary.model != null || summary.reasoningEffort != null;
  bool get _hasWorkspace => summary.workspaceRoot != null;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final secondaryStyle = Theme.of(context).textTheme.bodySmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        );
    return FloatingDetailPanel(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.45),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.shield_outlined, size: 16),
                  const SizedBox(width: 6),
                  Expanded(child: Text(
                    '权限 · ${summary.permissionLevel}',
                    style: secondaryStyle,
                  )),
                ],
              ),
              if (_hasPreview) ...[
                const SizedBox(height: 6),
                Text(
                  summary.preview!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: secondaryStyle,
                ),
              ],
              if (_hasModel) ...[
                const SizedBox(height: 6),
                Text(
                  [summary.model, summary.reasoningEffort]
                      .whereType<String>()
                      .join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: secondaryStyle,
                ),
              ],
              if (_hasWorkspace) ...[
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.folder_outlined, size: 16),
                    const SizedBox(width: 6),
                    Expanded(
                      child: SelectableText(
                        summary.workspaceRoot!,
                        style: secondaryStyle,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ChoiceSelector extends StatelessWidget {
  const _ChoiceSelector({
    super.key,
    required this.icon,
    required this.labelPrefix,
    required this.choices,
    required this.selectedId,
    required this.enabled,
    required this.onSelected,
  });

  final IconData icon;
  final String labelPrefix;
  final ProviderChoiceSet choices;
  final String? selectedId;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final selected = choices.option(selectedId);
    final available = choices.availableOptions;
    final canChoose = enabled && available.length > 1;
    return PopupMenuButton<String>(
      enabled: canChoose,
      initialValue: selectedId,
      tooltip: canChoose ? '选择${selected?.displayName ?? '选项'}' : '',
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final option in choices.options)
          PopupMenuItem<String>(
            value: option.id,
            enabled: option.enabled,
            child: _OptionLabel(
              title: option.displayName,
              description: option.enabled
                  ? option.description
                  : option.disabledReason ?? option.description,
            ),
          ),
      ],
      child: _SelectorFace(
        icon: icon,
        label: '$labelPrefix · ${selected?.displayName ??
            (available.isEmpty ? '无可用选项' : '请选择')}',
        enabled: canChoose,
      ),
    );
  }
}

class _ModelSelector extends StatelessWidget {
  const _ModelSelector({
    super.key,
    required this.catalog,
    required this.selected,
    required this.enabled,
    required this.onSelected,
  });

  final ModelCatalog catalog;
  final ModelSelection? selected;
  final bool enabled;
  final ValueChanged<ModelSelection> onSelected;

  @override
  Widget build(BuildContext context) {
    final available = catalog.availableSelections.toList(growable: false);
    final canChoose = enabled && available.length > 1;
    return PopupMenuButton<ModelSelection>(
      enabled: canChoose,
      initialValue: selected,
      tooltip: canChoose ? '选择模型' : '',
      onSelected: onSelected,
      itemBuilder: _entries,
      child: _SelectorFace(
        icon: Icons.memory_outlined,
        label: '模型 · ${_selectionLabel ??
            (available.isEmpty ? '无可用模型' : '请选择模型')}',
        enabled: canChoose,
      ),
    );
  }

  List<PopupMenuEntry<ModelSelection>> _entries(BuildContext context) {
    if (catalog case final FlatModelCatalog flat) {
      return [
        for (final model in flat.models)
          PopupMenuItem<ModelSelection>(
            value: FlatModelSelection(modelId: model.id),
            enabled: model.enabled,
            child: _OptionLabel(
              title: model.displayName,
              description: model.enabled
                  ? model.description
                  : model.disabledReason ?? model.description,
            ),
          ),
      ];
    }
    final grouped = catalog as GroupedModelCatalog;
    return [
      for (final provider in grouped.providers) ...[
        PopupMenuItem<ModelSelection>(
          enabled: false,
          height: 34,
          child: Text(
            provider.displayName,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ),
        for (final model in provider.models)
          PopupMenuItem<ModelSelection>(
            value: GroupedModelSelection(
              providerId: provider.id,
              modelId: model.id,
            ),
            enabled: model.enabled,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: _OptionLabel(
                title: model.displayName,
                description: model.enabled
                    ? model.description
                    : model.disabledReason ?? model.description,
              ),
            ),
          ),
      ],
    ];
  }

  String? get _selectionLabel {
    final model = catalog.modelFor(selected);
    if (model == null) return null;
    if (catalog case final GroupedModelCatalog grouped) {
      final provider = grouped.providerFor(selected);
      if (provider != null) {
        return '${provider.displayName} · ${model.displayName}';
      }
    }
    return model.displayName;
  }
}

class _SelectorFace extends StatelessWidget {
  const _SelectorFace({
    required this.icon,
    required this.label,
    required this.enabled,
  });

  final IconData icon;
  final String label;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? Theme.of(context).colorScheme.onSurface
        : Theme.of(context).colorScheme.onSurfaceVariant;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 180),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 17, color: color),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: color,
                    ),
              ),
            ),
            if (enabled) ...[
              const SizedBox(width: 2),
              Icon(Icons.arrow_drop_down, size: 18, color: color),
            ],
          ],
        ),
      ),
    );
  }
}

class _OptionLabel extends StatelessWidget {
  const _OptionLabel({required this.title, this.description});

  final String title;
  final String? description;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title),
          if (description != null && description!.isNotEmpty)
            Text(
              description!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      );
}

class _NoHistoryNotice extends StatelessWidget {
  const _NoHistoryNotice();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.info_outline, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Host 当前没有返回已提交的历史内容；连接后的实时输出仍会显示在这里。',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

String _statusLabel(ConversationStatus status) {
  return switch (status) {
    ConversationStatus.idle => '空闲',
    ConversationStatus.running => '运行中',
    ConversationStatus.waitingApproval => '等待审批',
    ConversationStatus.waitingUserInput => '等待输入',
    ConversationStatus.error => '错误',
    ConversationStatus.archived => '已归档',
  };
}
