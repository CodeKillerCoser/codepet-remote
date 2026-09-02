import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../application/conversations/conversation_timeline.dart';
import '../../application/sessions/device_session.dart';
import '../../core/errors/gateway_failures.dart';
import '../../core/ports/gateway_client.dart';
import '../../core/domain/models.dart';
import '../common/identity_icons.dart';
import 'widgets/conversation_timeline_view.dart';

const int _messagePageSize = 40;
const double _nearBottomThreshold = 160;
const Duration _interactionAcquireInterval = Duration(seconds: 10);
const String _unknownOutcomeMessage =
    '上次发送结果未知。请先刷新会话核对；确认后再次发送会创建新请求，仍可能产生重复任务。';
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
  GatewayEventWindow? _eventWindow;
  Timer? _interactionTimer;
  final Set<String> _appliedCursors = {};
  final Set<String> _refreshingTurns = {};
  DeviceSessionRuntimeLease? _observedLease;
  _CapabilityBinding? _binding;
  GatewayProvider? _provider;
  ConversationDetail? _detail;
  List<ConversationTimelineBlock> _timeline = const [];
  int? _detailFrameCallbackId;
  bool _followPendingDetailFrame = false;
  String? _error;
  String? _sendError;
  String? _interactionError;
  String? _accessModeId;
  String? _reasoningEffortId;
  ModelSelection? _modelSelection;
  _PendingTurnSend? _pendingSend;
  int _runtimeEpoch = 0;
  bool _sending = false;
  bool _interactionAcquired = false;
  bool _interactionRequestInFlight = false;
  bool _selectionInitializedFromInteraction = false;
  bool _outcomeUnknown = false;
  bool _staleCapabilities = false;
  bool _refreshingTerminal = false;
  bool _metadataExpanded = false;
  bool _messagesExpanded = true;
  int _hiddenMessageCount = 0;
  bool _showScrollToBottom = false;
  bool _followOnExpand = true;
  int _scrollRequest = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_handleScroll);
    _draftController.addListener(_draftChanged);
    widget.session.addListener(_sessionChanged);
    _observedLease = widget.session.runtimeLease;
    unawaited(_bindRuntime());
  }

  @override
  void didUpdateWidget(ConversationDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session == widget.session &&
        conversationRoutingKey(oldWidget.conversation) ==
            conversationRoutingKey(widget.conversation)) {
      return;
    }
    oldWidget.session.removeListener(_sessionChanged);
    widget.session.addListener(_sessionChanged);
    _observedLease = widget.session.runtimeLease;
    unawaited(_bindRuntime());
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    _runtimeEpoch++;
    _interactionTimer?.cancel();
    _cancelPendingDetailFrame();
    unawaited(_eventWindow?.close());
    _draftController.removeListener(_draftChanged);
    _draftController.dispose();
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _draftChanged() {
    if (mounted) setState(() {});
  }

  void _sessionChanged() {
    final lease = widget.session.runtimeLease;
    final conversation = _currentConversation;
    final provider = widget.session.providerForConversation(conversation);
    final nextBinding = lease == null || provider == null
        ? null
        : _CapabilityBinding.from(lease, provider);
    if (_sameLease(_observedLease, lease) && _binding == nextBinding) {
      if (mounted && _provider != provider) {
        setState(() {
          _provider = provider;
        });
      }
      return;
    }
    _observedLease = lease;
    unawaited(_bindRuntime());
  }

  ConversationSummary get _currentConversation {
    final key = conversationRoutingKey(widget.conversation);
    for (final conversation in widget.session.conversations) {
      if (conversationRoutingKey(conversation) == key) return conversation;
    }
    return widget.conversation;
  }

  bool _sameLease(
    DeviceSessionRuntimeLease? left,
    DeviceSessionRuntimeLease? right,
  ) =>
      left?.generation == right?.generation &&
      identical(left?.client, right?.client);

  Future<void> _bindRuntime() async {
    final epoch = ++_runtimeEpoch;
    _interactionTimer?.cancel();
    _interactionTimer = null;
    _cancelPendingDetailFrame();
    final previousBinding = _binding;
    final previousWindow = _eventWindow;
    _eventWindow = null;
    _appliedCursors.clear();
    _refreshingTurns.clear();
    final lease = widget.session.runtimeLease;
    final conversation = _currentConversation;
    final provider = widget.session.providerForConversation(conversation);
    final binding = lease == null || provider == null
        ? null
        : _CapabilityBinding.from(lease, provider);
    final pendingSend = _pendingSend;
    final sameConversation = pendingSend != null &&
        conversationRoutingKey(pendingSend.conversation) ==
            conversationRoutingKey(conversation);
    final preserveUnknown = sameConversation &&
        (_outcomeUnknown ||
            (_sending && previousBinding != binding));
    if (mounted) {
      setState(() {
        _observedLease = lease;
        _binding = binding;
        _provider = provider;
        _replaceDetail(null);
        _error = null;
        _sendError = preserveUnknown ? _unknownOutcomeMessage : null;
        _interactionError = null;
        _accessModeId = null;
        _reasoningEffortId = null;
        _modelSelection = null;
        _sending = false;
        _interactionAcquired = false;
        _interactionRequestInFlight = false;
        _selectionInitializedFromInteraction = false;
        _outcomeUnknown = preserveUnknown;
        if (!preserveUnknown) {
          _pendingSend = null;
        }
        _staleCapabilities = false;
        _refreshingTerminal = false;
        _showScrollToBottom = false;
        _scrollRequest++;
      });
    }
    if (previousWindow != null) unawaited(previousWindow.close());
    if (lease == null || provider == null || binding == null) return;
    if (!provider.methods.contains('conversation.get')) {
      if (mounted && epoch == _runtimeEpoch) {
        setState(() {
          _error = '当前 Provider 不支持加载会话详情。';
        });
      }
      return;
    }
    if (provider.methods.contains('turn.send')) {
      _startInteractionLoop(
        lease: lease,
        binding: binding,
        conversation: conversation,
        epoch: epoch,
      );
    }
    await _loadSnapshot(
      lease: lease,
      binding: binding,
      conversation: conversation,
      epoch: epoch,
      initializeSelection: true,
    );
  }

  void _startInteractionLoop({
    required DeviceSessionRuntimeLease lease,
    required _CapabilityBinding binding,
    required ConversationSummary conversation,
    required int epoch,
  }) {
    unawaited(_acquireInteraction(
      lease: lease,
      binding: binding,
      conversation: conversation,
      epoch: epoch,
    ));
    _interactionTimer = Timer.periodic(_interactionAcquireInterval, (_) {
      unawaited(_acquireInteraction(
        lease: lease,
        binding: binding,
        conversation: conversation,
        epoch: epoch,
      ));
    });
  }

  Future<void> _acquireInteraction({
    required DeviceSessionRuntimeLease lease,
    required _CapabilityBinding binding,
    required ConversationSummary conversation,
    required int epoch,
  }) async {
    if (_interactionRequestInFlight ||
        !_acceptsRuntime(epoch, lease, binding)) {
      return;
    }
    _interactionRequestInFlight = true;
    try {
      final interaction = await lease.client.acquireInteraction(conversation);
      if (!_acceptsRuntime(epoch, lease, binding)) return;
      setState(() {
        _interactionAcquired = true;
        _interactionError = null;
        if (!_selectionInitializedFromInteraction &&
            _hasSelection(interaction.selection)) {
          _initializeSelectionFrom(interaction.selection);
          _selectionInitializedFromInteraction = true;
        }
      });
    } catch (error) {
      if (!_acceptsRuntime(epoch, lease, binding)) return;
      setState(() {
        _interactionAcquired = false;
        _interactionError = _interactionFailureMessage(error);
      });
    } finally {
      if (epoch == _runtimeEpoch) _interactionRequestInFlight = false;
    }
  }

  bool _hasSelection(TurnSendSelection selection) =>
      selection.accessModeId != null ||
      selection.reasoningEffortId != null ||
      selection.model != null;

  String _interactionFailureMessage(Object error) {
    if (error is GatewayProtocolException &&
        error.code == 'conversation_write_conflict') {
      return '该会话正在被另一个客户端写入，暂时无法继续对话。';
    }
    return '无法获取会话交互权：$error';
  }

  Future<void> _loadSnapshot({
    required DeviceSessionRuntimeLease lease,
    required _CapabilityBinding binding,
    required ConversationSummary conversation,
    required int epoch,
    bool initializeSelection = false,
    String? completedTurnId,
    bool? followBottom,
  }) async {
    final shouldFollowBottom = followBottom ?? _detail == null;
    if (mounted) setState(() => _error = null);
    final window = lease.client.openEventWindow();
    try {
      final snapshot = await lease.client.getConversation(conversation);
      if (!_acceptsRuntime(epoch, lease, binding)) {
        await window.close();
        return;
      }
      var detail = snapshot.detail;
      final previous = _detail;
      if (completedTurnId != null && previous != null) {
        detail = previous.installCommittedSnapshot(
          detail,
          completedTurnId: completedTurnId,
        );
      }
      final baseline = window.startCursor;
      if (baseline == null) {
        throw const GatewayCursorGapException(
          'Detail event window has no subscribed baseline cursor',
        );
      }
      final previousWindow = _eventWindow;
      _eventWindow = null;
      if (previousWindow != null) unawaited(previousWindow.close());
      if (!_acceptsRuntime(epoch, lease, binding)) {
        await window.close();
        return;
      }
      _eventWindow = window;
      setState(() {
        _replaceDetail(detail);
        _provider = widget.session.providerForConversation(conversation);
        if (initializeSelection && !_selectionInitializedFromInteraction) {
          _initializeSelection(detail.summary);
        }
        final timelineLength = _timeline.length;
        if (previous == null) {
          _hiddenMessageCount = timelineLength > _messagePageSize
              ? timelineLength - _messagePageSize
              : 0;
        } else {
          _convergeHiddenMessageCount(timelineLength);
        }
      });
      window.install(
        baselineCursor: baseline,
        snapshotCursor: snapshot.snapshotCursor,
        onEvent: (event) => _applyEvent(event, epoch, lease, binding),
        onError: (Object error, StackTrace _) {
          if (_acceptsRuntime(epoch, lease, binding)) {
            setState(() {
              _replaceDetail(null);
              _error = '事件流异常：$error';
              _showScrollToBottom = false;
              _scrollRequest++;
            });
          }
          _eventWindow = null;
          unawaited(window.close());
        },
      );
      if (shouldFollowBottom && _messagesExpanded) {
        _scrollToBottom();
      } else {
        _scheduleScrollStateUpdate();
      }
    } catch (error) {
      await window.close();
      if (_acceptsRuntime(epoch, lease, binding)) {
        await _eventWindow?.close();
        _eventWindow = null;
        setState(() {
          _replaceDetail(null);
          _error = error.toString();
          _showScrollToBottom = false;
          _scrollRequest++;
        });
      }
    }
  }

  bool _acceptsRuntime(
    int epoch,
    DeviceSessionRuntimeLease lease,
    _CapabilityBinding binding,
  ) =>
      mounted &&
      epoch == _runtimeEpoch &&
      _binding == binding &&
      widget.session.ownsRuntimeLease(lease);

  void _replaceDetail(ConversationDetail? detail) {
    _detail = detail;
    _timeline = detail == null
        ? const []
        : _timelineProjector.project(detail);
  }

  void _scheduleDetailFrame({required bool followBottom}) {
    _followPendingDetailFrame |= followBottom;
    if (_detailFrameCallbackId != null) return;
    final epoch = _runtimeEpoch;
    _detailFrameCallbackId =
        SchedulerBinding.instance.scheduleFrameCallback((_) {
      _detailFrameCallbackId = null;
      final shouldFollowBottom = _followPendingDetailFrame;
      _followPendingDetailFrame = false;
      if (!mounted || epoch != _runtimeEpoch) return;
      final detail = _detail;
      setState(() {
        _timeline = detail == null
            ? const []
            : _timelineProjector.project(detail);
        _convergeHiddenMessageCount(_timeline.length);
      });
      if (shouldFollowBottom && _messagesExpanded) {
        _followStreamingOutput();
      } else {
        _scheduleScrollStateUpdate();
      }
    });
  }

  void _cancelPendingDetailFrame() {
    final callbackId = _detailFrameCallbackId;
    if (callbackId != null) {
      SchedulerBinding.instance.cancelFrameCallbackWithId(callbackId);
      _detailFrameCallbackId = null;
    }
    _followPendingDetailFrame = false;
  }

  void _initializeSelection(ConversationSummary summary) {
    _initializeSelectionFrom(summary.turnSendSelection);
  }

  void _initializeSelectionFrom(TurnSendSelection? current) {
    final capabilities = _provider?.capabilities.turnSend;
    _accessModeId = _initialChoice(
      capabilities?.accessMode,
      current?.accessModeId,
    );
    _reasoningEffortId = _initialChoice(
      capabilities?.reasoningEffort,
      current?.reasoningEffortId,
    );
    final catalog = capabilities?.modelCatalog;
    final currentModel = current?.model;
    if (catalog == null) {
      _modelSelection = null;
    } else if (catalog.accepts(currentModel)) {
      _modelSelection = currentModel;
    } else {
      final available = catalog.availableSelections.toList(growable: false);
      final defaultSelection = catalog.defaultSelection;
      _modelSelection = catalog.accepts(defaultSelection)
          ? defaultSelection
          : available.length == 1
              ? available.single
              : null;
    }
  }

  String? _initialChoice(ProviderChoiceSet? choices, String? current) {
    if (choices == null) return null;
    if (choices.accepts(current)) return current;
    if (choices.accepts(choices.defaultId)) return choices.defaultId;
    final available = choices.availableOptions;
    return available.length == 1 ? available.single.id : null;
  }

  void _applyEvent(
    GatewayEvent event,
    int epoch,
    DeviceSessionRuntimeLease lease,
    _CapabilityBinding binding,
  ) {
    if (!_acceptsRuntime(epoch, lease, binding) ||
        !_appliedCursors.add(event.eventCursor)) {
      return;
    }
    final detail = _detail;
    if (detail == null) return;
    final wasNearBottom = _messagesExpanded && _isNearBottom();
    final next = detail.apply(event);
    if (identical(next, detail)) {
      return;
    }
    _detail = next;
    _scheduleDetailFrame(
      followBottom: event is TurnOutputDeltaEvent && wasNearBottom,
    );
    if (event is TurnUpsertedEvent &&
        event.turn.conversationId == detail.summary.id &&
        event.turn.status.isTerminal &&
        _refreshingTurns.add(event.turn.id)) {
      unawaited(_reloadCompletedTurn(
        event.turn.id,
        followBottom: wasNearBottom,
        epoch: epoch,
        lease: lease,
        binding: binding,
      ));
    }
  }

  Future<void> _reloadCompletedTurn(
    String turnId, {
    required bool followBottom,
    required int epoch,
    required DeviceSessionRuntimeLease lease,
    required _CapabilityBinding binding,
  }) async {
    if (_acceptsRuntime(epoch, lease, binding)) {
      setState(() => _refreshingTerminal = true);
    }
    try {
      await _loadSnapshot(
        lease: lease,
        binding: binding,
        conversation: _currentConversation,
        epoch: epoch,
        completedTurnId: turnId,
        followBottom: followBottom,
      );
      final detail = _detail;
      if (mounted && detail != null) {
        setState(() {
          _replaceDetail(
            detail.installCommittedSnapshot(
              detail,
              completedTurnId: turnId,
            ),
          );
          _convergeHiddenMessageCount(_timeline.length);
        });
      }
    } finally {
      _refreshingTurns.remove(turnId);
      if (_acceptsRuntime(epoch, lease, binding)) {
        setState(() => _refreshingTerminal = false);
      }
    }
  }

  TurnSendSelection get _selection => TurnSendSelection(
        accessModeId: _accessModeId,
        reasoningEffortId: _reasoningEffortId,
        model: _modelSelection,
      );

  bool get _selectionValid {
    final capabilities = _provider?.capabilities.turnSend;
    return capabilities != null && capabilities.accepts(_selection);
  }

  bool get _conversationBlocksSend {
    final detail = _detail;
    if (detail == null) return true;
    if (detail.activeTurn != null) return true;
    return switch (detail.summary.status) {
      ConversationStatus.running ||
      ConversationStatus.waitingApproval ||
      ConversationStatus.waitingUserInput ||
      ConversationStatus.archived => true,
      ConversationStatus.idle || ConversationStatus.error => false,
    };
  }

  bool get _canSend {
    final lease = widget.session.runtimeLease;
    final provider = _provider;
    return lease != null &&
        widget.session.ownsRuntimeLease(lease) &&
        provider != null &&
        provider.status == ProviderStatus.ready &&
        provider.methods.contains('turn.send') &&
        provider.capabilities.turnSend != null &&
        _interactionAcquired &&
        !_staleCapabilities &&
        !_sending &&
        !_outcomeUnknown &&
        !_refreshingTerminal &&
        !_conversationBlocksSend &&
        _selectionValid &&
        _draftController.text.trim().isNotEmpty;
  }

  bool get _composerEnabled =>
      _detail != null &&
      _provider?.status == ProviderStatus.ready &&
      _provider?.methods.contains('turn.send') == true &&
      _interactionAcquired &&
      !_staleCapabilities &&
      !_sending &&
      !_refreshingTerminal &&
      !_conversationBlocksSend &&
      !_outcomeUnknown;

  Future<void> _send() async {
    if (!_canSend) return;
    final lease = widget.session.runtimeLease;
    final provider = _provider;
    final binding = _binding;
    if (lease == null || provider == null || binding == null) return;
    final epoch = _runtimeEpoch;
    final currentConversation = _currentConversation;
    final attempt = _PendingTurnSend(
      clientRequestId: _newClientRequestId(),
      text: _draftController.text,
      selection: _selection,
      capabilityRevision: provider.capabilities.revision,
      route: provider.route,
      conversation: currentConversation,
    );
    setState(() {
      _sending = true;
      _sendError = null;
      _pendingSend = attempt;
    });
    try {
      final receipt = await lease.client.sendTurn(
        route: attempt.route,
        conversation: attempt.conversation,
        clientRequestId: attempt.clientRequestId,
        capabilityRevision: attempt.capabilityRevision,
        text: attempt.text,
        selection: attempt.selection,
      );
      if (!_acceptsRuntime(epoch, lease, binding)) return;
      setState(() {
        _replaceDetail(_detail?.accept(receipt));
        _accessModeId = receipt.effectiveSelection.accessModeId;
        _reasoningEffortId = receipt.effectiveSelection.reasoningEffortId;
        _modelSelection = receipt.effectiveSelection.model;
        _pendingSend = null;
        _outcomeUnknown = false;
        _sendError = null;
      });
      _draftController.clear();
      _scrollToBottom();
    } catch (error) {
      if (!_acceptsRuntime(epoch, lease, binding)) return;
      if (error is GatewayProtocolException &&
          error.code == 'stale_capability_revision') {
        setState(() {
          _staleCapabilities = true;
          _accessModeId = null;
          _reasoningEffortId = null;
          _modelSelection = null;
          _pendingSend = null;
          _outcomeUnknown = false;
          _sendError = 'Provider 能力已更新，正在重新连接并刷新选项。';
        });
        unawaited(widget.session.connect());
      } else if (isGatewayOutcomeUnknown(error)) {
        setState(() {
          _outcomeUnknown = true;
          _sendError = _unknownOutcomeMessage;
        });
        unawaited(_bindRuntime());
      } else {
        setState(() {
          _pendingSend = null;
          _outcomeUnknown = false;
          _sendError = error.toString();
        });
      }
    } finally {
      if (_acceptsRuntime(epoch, lease, binding)) {
        setState(() => _sending = false);
      }
    }
  }

  void _clearUnknownOutcome() {
    if (!_outcomeUnknown) return;
    setState(() {
      _pendingSend = null;
      _outcomeUnknown = false;
      _sendError = null;
    });
  }

  String _newClientRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

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
    final shouldShow = _messagesExpanded &&
        _scrollController.hasClients &&
        !_isNearBottom();
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
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _scrollRequest ||
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

  void _toggleMessages() {
    final willExpand = !_messagesExpanded;
    final shouldFollowBottom = willExpand
        ? _followOnExpand
        : _isNearBottom();
    setState(() {
      _messagesExpanded = willExpand;
      if (!willExpand) {
        _followOnExpand = shouldFollowBottom;
        _showScrollToBottom = false;
        _scrollRequest++;
      }
    });
    if (willExpand && shouldFollowBottom) {
      _scrollToBottom();
    } else {
      _scheduleScrollStateUpdate();
    }
  }

  void _showEarlierMessages() {
    if (_hiddenMessageCount == 0) return;
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
    final providerIdentity = provider == null
        ? widget.conversation.providerId
        : provider.icon ?? provider.providerType;
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: Row(
          children: [
            Icon(
              providerIconData(providerIdentity),
              key: const Key('conversation-provider-icon'),
              size: 22,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _detail?.summary.title ?? widget.conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      body: _buildBody(),
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
      if (widget.session.connectionState == DeviceConnectionState.offline) {
        return const _DetailUnavailable(
          icon: Icons.link_off_outlined,
          title: '设备已离线',
          message: '重新连接后会自动刷新会话；未发送的文字会保留。',
        );
      }
      if (widget.session.connectionState == DeviceConnectionState.failed) {
        return _DetailUnavailable(
          icon: Icons.cloud_off_outlined,
          title: '连接失败',
          message: widget.session.error ?? '正在等待重新连接。',
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
    final centerBlockIndex = timeline.length > _messagePageSize
        ? timeline.length - _messagePageSize
        : 0;
    final centerBlockCount = timeline.length - centerBlockIndex;
    final earlierVisibleBlockCount =
        centerBlockIndex - _hiddenMessageCount;
    final growsUpward =
        _messagesExpanded && timeline.length > _messagePageSize;
    return NotificationListener<ScrollStartNotification>(
      onNotification: (notification) {
        if (notification.dragDetails != null) {
          _scrollRequest++;
        }
        return false;
      },
      child: CustomScrollView(
        key: const Key('conversation-detail'),
        controller: _scrollController,
        center: growsUpward ? _messagesCenterKey : null,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            sliver: SliverList(
              delegate: SliverChildListDelegate.fixed([
                _ConversationMetadata(
                  summary: detail.summary,
                  expanded: _metadataExpanded,
                  onTap: () => setState(() {
                    _metadataExpanded = !_metadataExpanded;
                  }),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  MaterialBanner(
                    content: Text(_error!),
                    actions: [
                      TextButton(
                        onPressed: () => unawaited(_bindRuntime()),
                        child: const Text('重新加载'),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 20),
                _MessagesSectionHeader(
                  expanded: _messagesExpanded,
                  count: timeline.length,
                  onTap: _toggleMessages,
                ),
                if (_messagesExpanded && _hiddenMessageCount > 0) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton.icon(
                      key: const Key('show-earlier-messages'),
                      onPressed: _showEarlierMessages,
                      icon: const Icon(Icons.expand_less),
                      label: const Text('显示更早消息'),
                    ),
                  ),
                ],
                if (_messagesExpanded) const SizedBox(height: 12),
              ]),
            ),
          ),
          if (_messagesExpanded && earlierVisibleBlockCount > 0)
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
                        ),
                      );
                    }),
                ]),
              ),
            ),
          SliverPadding(
            key: _messagesCenterKey,
            padding: EdgeInsets.fromLTRB(
              _messagesExpanded ? 16 : 0,
              0,
              _messagesExpanded ? 16 : 0,
              28,
            ),
            sliver: !_messagesExpanded
                ? const SliverToBoxAdapter(child: SizedBox.shrink())
                : timeline.isEmpty
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
                        onPressed: _binding == null
                            ? null
                            : () => unawaited(_bindRuntime()),
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('刷新会话核对'),
                      ),
                      TextButton(
                        key: const Key('turn-unknown-dismiss'),
                        onPressed:
                            _detail == null ? null : _clearUnknownOutcome,
                        child: const Text('已核对，继续编辑'),
                      ),
                    ],
                  ),
              ],
              if (_interactionError != null) ...[
                const SizedBox(height: 4),
                Text(
                  _interactionError!,
                  key: const Key('interaction-error'),
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
                                setState(() => _accessModeId = value);
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
                                setState(() => _reasoningEffortId = value);
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
                                setState(() => _modelSelection = value);
                              },
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
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

  String get _composerHint {
    if (widget.session.runtimeLease == null) return '设备离线';
    if (_staleCapabilities) return 'Provider 能力已变化，正在刷新';
    if (_detail == null) return '正在加载会话';
    if (_outcomeUnknown) return '发送结果未知，请先刷新会话核对';
    if (_refreshingTerminal) return '正在收敛本轮结果';
    final status = _detail!.summary.status;
    if (_detail!.activeTurn != null || status == ConversationStatus.running) {
      return '当前任务仍在运行';
    }
    if (status == ConversationStatus.waitingApproval) return '当前任务正在等待审批';
    if (status == ConversationStatus.waitingUserInput) {
      return '结构化用户输入暂不支持';
    }
    if (status == ConversationStatus.archived) return '已归档会话不能继续';
    if (_provider?.methods.contains('turn.send') != true) {
      return '当前 Provider 不支持继续对话';
    }
    if (!_interactionAcquired) {
      return _interactionError == null ? '正在获取会话交互权' : '暂时无法继续对话';
    }
    if (!_selectionValid) return '请先选择可用的发送选项';
    return '继续对话';
  }
}

class _DetailUnavailable extends StatelessWidget {
  const _DetailUnavailable({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 34),
              const SizedBox(height: 12),
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              Text(message, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
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

class _CapabilityBinding {
  const _CapabilityBinding({
    required this.generation,
    required this.client,
    required this.route,
    required this.revision,
  });

  factory _CapabilityBinding.from(
    DeviceSessionRuntimeLease lease,
    GatewayProvider provider,
  ) =>
      _CapabilityBinding(
        generation: lease.generation,
        client: lease.client,
        route: provider.route,
        revision: provider.capabilities.revision,
      );

  final int generation;
  final GatewayClient client;
  final GatewayProviderRoute route;
  final String revision;

  @override
  bool operator ==(Object other) =>
      other is _CapabilityBinding &&
      other.generation == generation &&
      identical(other.client, client) &&
      other.route == route &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(
        generation,
        identityHashCode(client),
        route,
        revision,
      );
}

class _PendingTurnSend {
  const _PendingTurnSend({
    required this.clientRequestId,
    required this.text,
    required this.selection,
    required this.capabilityRevision,
    required this.route,
    required this.conversation,
  });

  final String clientRequestId;
  final String text;
  final TurnSendSelection selection;
  final String capabilityRevision;
  final GatewayProviderRoute route;
  final ConversationSummary conversation;
}

class _MessagesSectionHeader extends StatelessWidget {
  const _MessagesSectionHeader({
    required this.expanded,
    required this.count,
    required this.onTap,
  });

  final bool expanded;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          key: const Key('messages-section-toggle'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        '消息与事件',
                        style: Theme.of(context)
                            .textTheme
                            .titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '$count',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  semanticLabel: expanded ? '折叠消息与事件' : '展开消息与事件',
                ),
              ],
            ),
          ),
        ),
      );
}

class _ConversationMetadata extends StatelessWidget {
  const _ConversationMetadata({
    required this.summary,
    required this.expanded,
    required this.onTap,
  });

  final ConversationSummary summary;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const Key('conversation-metadata-toggle'),
        onTap: onTap,
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: summary.status == ConversationStatus.running
                        ? Colors.green
                        : colorScheme.outline,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _statusLabel(summary.status),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Text(
                  summary.permissionLevel,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(width: 4),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  semanticLabel: expanded ? '折叠会话详情' : '展开会话详情',
                ),
              ],
            ),
            if (expanded &&
                summary.preview != null &&
                summary.preview!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(summary.preview!),
            ],
            if (expanded &&
                (summary.model != null || summary.reasoningEffort != null)) ...[
              const SizedBox(height: 10),
              Text(
                [summary.model, summary.reasoningEffort]
                    .whereType<String>()
                    .join(' · '),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
            if (expanded && summary.workspaceRoot != null) ...[
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.folder_outlined, size: 16),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary.workspaceRoot!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
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
