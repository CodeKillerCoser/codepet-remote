import 'dart:async';
import 'dart:math';

import '../../core/domain/models.dart';
import '../errors/application_failures.dart';
import '../sessions/device_session.dart';
import '../support/application_notifier.dart';
import '../sync/gateway_event_window.dart';

const Duration _fallbackInteractionRenewal = Duration(seconds: 10);
const String unknownTurnOutcomeMessage =
    '上次发送结果未知。请先刷新会话核对；确认后再次发送会创建新请求，仍可能产生重复任务。';

class ConversationDetailController extends ApplicationNotifier {
  ConversationDetailController({
    required DeviceSession session,
    required ConversationSummary conversation,
    DateTime Function()? now,
  })  : _session = session,
        _now = now ?? (() => DateTime.now().toUtc()) {
    _conversation = conversation;
    _observedLease = session.runtimeLease;
    session.addListener(_sessionChanged);
  }

  DeviceSession _session;
  late ConversationSummary _conversation;
  final DateTime Function() _now;
  GatewayEventWindow? _eventWindow;
  Timer? _interactionTimer;
  final Set<String> _appliedCursors = {};
  final Set<String> _refreshingTurns = {};
  DeviceSessionRuntimeLease? _observedLease;
  _CapabilityBinding? _binding;
  GatewayProvider? _provider;
  ConversationDetail? _detail;
  PendingTurnSend? _pendingSend;
  String? _error;
  String? _sendError;
  String? _interactionError;
  String? _accessModeId;
  String? _reasoningEffortId;
  ModelSelection? _modelSelection;
  int _runtimeEpoch = 0;
  bool _disposed = false;
  bool _sending = false;
  bool _interactionAcquired = false;
  bool _interactionRequestInFlight = false;
  bool _selectionInitializedFromInteraction = false;
  bool _outcomeUnknown = false;
  bool _staleCapabilities = false;
  bool _refreshingTerminal = false;
  bool _followOutputRequested = false;

  DeviceSession get session => _session;
  GatewayProvider? get provider => _provider;
  ConversationDetail? get detail => _detail;
  String? get error => _error;
  String? get sendError => _sendError;
  String? get interactionError => _interactionError;
  String? get accessModeId => _accessModeId;
  String? get reasoningEffortId => _reasoningEffortId;
  ModelSelection? get modelSelection => _modelSelection;
  bool get sending => _sending;
  bool get interactionAcquired => _interactionAcquired;
  bool get outcomeUnknown => _outcomeUnknown;
  bool get staleCapabilities => _staleCapabilities;
  bool get refreshingTerminal => _refreshingTerminal;

  ConversationSummary get currentConversation {
    final key = conversationRoutingKey(_conversation);
    for (final conversation in _session.conversations) {
      if (conversationRoutingKey(conversation) == key) return conversation;
    }
    return _conversation;
  }

  bool consumeFollowOutputRequest() {
    final value = _followOutputRequested;
    _followOutputRequested = false;
    return value;
  }

  void replace({
    required DeviceSession session,
    required ConversationSummary conversation,
  }) {
    if (!identical(_session, session)) {
      _session.removeListener(_sessionChanged);
      _session = session;
      _session.addListener(_sessionChanged);
    }
    _conversation = conversation;
    _observedLease = _session.runtimeLease;
    unawaited(reload());
  }

  void _sessionChanged() {
    final lease = _session.runtimeLease;
    final conversation = currentConversation;
    final provider = _session.providerForConversation(conversation);
    final nextBinding = lease == null || provider == null
        ? null
        : _CapabilityBinding.from(lease, provider);
    if (_sameLease(_observedLease, lease) && _binding == nextBinding) {
      if (_provider != provider) {
        _provider = provider;
        notifyApplicationListeners();
      }
      return;
    }
    _observedLease = lease;
    unawaited(reload());
  }

  bool _sameLease(
    DeviceSessionRuntimeLease? left,
    DeviceSessionRuntimeLease? right,
  ) => left?.sameRuntime(right) ?? right == null;

  Future<void> reload() async {
    final epoch = ++_runtimeEpoch;
    _interactionTimer?.cancel();
    _interactionTimer = null;
    final previousBinding = _binding;
    final previousWindow = _eventWindow;
    _eventWindow = null;
    _appliedCursors.clear();
    _refreshingTurns.clear();
    final lease = _session.runtimeLease;
    final conversation = currentConversation;
    final provider = _session.providerForConversation(conversation);
    final binding = lease == null || provider == null
        ? null
        : _CapabilityBinding.from(lease, provider);
    final pendingSend = _pendingSend;
    final sameConversation = pendingSend != null &&
        conversationRoutingKey(pendingSend.conversation) ==
            conversationRoutingKey(conversation);
    final preserveUnknown = sameConversation &&
        (_outcomeUnknown || (_sending && previousBinding != binding));
    _observedLease = lease;
    _binding = binding;
    _provider = provider;
    _detail = null;
    _error = null;
    _sendError = preserveUnknown ? unknownTurnOutcomeMessage : null;
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
    notifyApplicationListeners();
    if (previousWindow != null) unawaited(previousWindow.close());
    if (lease == null || provider == null || binding == null) return;
    if (!provider.methods.contains('conversation.get')) {
      if (_acceptsRuntime(epoch, lease, binding)) {
        _error = '当前 Provider 不支持加载会话详情。';
        notifyApplicationListeners();
      }
      return;
    }
    if (provider.methods.contains('turn.send')) {
      unawaited(_acquireInteraction(
        lease: lease,
        binding: binding,
        conversation: conversation,
        epoch: epoch,
      ));
    }
    await _loadSnapshot(
      lease: lease,
      binding: binding,
      conversation: conversation,
      epoch: epoch,
      initializeSelection: true,
    );
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
      final interaction = await lease.acquireInteraction(conversation);
      if (!_acceptsRuntime(epoch, lease, binding)) return;
      _interactionAcquired = true;
      _interactionError = null;
      if (!_selectionInitializedFromInteraction &&
          _hasSelection(interaction.selection)) {
        _initializeSelectionFrom(interaction.selection);
        _selectionInitializedFromInteraction = true;
      }
      _scheduleInteractionRenewal(
        interaction: interaction,
        lease: lease,
        binding: binding,
        conversation: conversation,
        epoch: epoch,
      );
      notifyApplicationListeners();
    } catch (error) {
      if (!_acceptsRuntime(epoch, lease, binding)) return;
      _interactionAcquired = false;
      _interactionError = _interactionFailureMessage(error);
      _scheduleInteractionRetry(
        lease: lease,
        binding: binding,
        conversation: conversation,
        epoch: epoch,
      );
      notifyApplicationListeners();
    } finally {
      if (epoch == _runtimeEpoch) _interactionRequestInFlight = false;
    }
  }

  void _scheduleInteractionRenewal({
    required ConversationInteraction interaction,
    required DeviceSessionRuntimeLease lease,
    required _CapabilityBinding binding,
    required ConversationSummary conversation,
    required int epoch,
  }) {
    _interactionTimer?.cancel();
    final expiresAt = interaction.leaseExpiresAt;
    var delay = _fallbackInteractionRenewal;
    if (expiresAt != null) {
      final remaining = expiresAt.difference(_now());
      final safetyMilliseconds = min(
        5000,
        max(500, remaining.inMilliseconds ~/ 5),
      );
      delay = remaining - Duration(milliseconds: safetyMilliseconds);
      if (delay < const Duration(milliseconds: 250)) {
        delay = const Duration(milliseconds: 250);
      }
    }
    _interactionTimer = Timer(delay, () {
      unawaited(_acquireInteraction(
        lease: lease,
        binding: binding,
        conversation: conversation,
        epoch: epoch,
      ));
    });
  }

  void _scheduleInteractionRetry({
    required DeviceSessionRuntimeLease lease,
    required _CapabilityBinding binding,
    required ConversationSummary conversation,
    required int epoch,
  }) {
    _interactionTimer?.cancel();
    _interactionTimer = Timer(_fallbackInteractionRenewal, () {
      unawaited(_acquireInteraction(
        lease: lease,
        binding: binding,
        conversation: conversation,
        epoch: epoch,
      ));
    });
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
  }) async {
    _error = null;
    notifyApplicationListeners();
    final window = lease.openEventWindow();
    try {
      final snapshot = await lease.getConversation(conversation);
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
      _detail = detail;
      _provider = _session.providerForConversation(conversation);
      if (initializeSelection && !_selectionInitializedFromInteraction) {
        _initializeSelection(detail.summary);
      }
      notifyApplicationListeners();
      window.install(
        baselineCursor: baseline,
        snapshotCursor: snapshot.snapshotCursor,
        onEvent: (event) => _applyEvent(event, epoch, lease, binding),
        onError: (Object error, StackTrace _) {
          if (_acceptsRuntime(epoch, lease, binding)) {
            _detail = null;
            _error = '事件流异常：$error';
            notifyApplicationListeners();
          }
          _eventWindow = null;
          unawaited(window.close());
        },
      );
    } catch (error) {
      await window.close();
      if (_acceptsRuntime(epoch, lease, binding)) {
        await _eventWindow?.close();
        _eventWindow = null;
        _detail = null;
        _error = error.toString();
        notifyApplicationListeners();
      }
    }
  }

  bool _acceptsRuntime(
    int epoch,
    DeviceSessionRuntimeLease lease,
    _CapabilityBinding binding,
  ) =>
      !_disposed &&
      epoch == _runtimeEpoch &&
      _binding == binding &&
      _session.ownsRuntimeLease(lease);

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

  void selectAccessMode(String? value) {
    _accessModeId = value;
    notifyApplicationListeners();
  }

  void selectReasoningEffort(String? value) {
    _reasoningEffortId = value;
    notifyApplicationListeners();
  }

  void selectModel(ModelSelection? value) {
    _modelSelection = value;
    notifyApplicationListeners();
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
    final next = detail.apply(event);
    if (identical(next, detail)) return;
    _detail = next;
    _followOutputRequested |= event is TurnOutputDeltaEvent;
    notifyApplicationListeners();
    if (event is TurnUpsertedEvent &&
        event.turn.conversationId == detail.summary.id &&
        event.turn.status.isTerminal &&
        _refreshingTurns.add(event.turn.id)) {
      unawaited(_reloadCompletedTurn(
        event.turn.id,
        epoch: epoch,
        lease: lease,
        binding: binding,
      ));
    }
  }

  Future<void> _reloadCompletedTurn(
    String turnId, {
    required int epoch,
    required DeviceSessionRuntimeLease lease,
    required _CapabilityBinding binding,
  }) async {
    if (_acceptsRuntime(epoch, lease, binding)) {
      _refreshingTerminal = true;
      notifyApplicationListeners();
    }
    try {
      await _loadSnapshot(
        lease: lease,
        binding: binding,
        conversation: currentConversation,
        epoch: epoch,
        completedTurnId: turnId,
      );
    } finally {
      _refreshingTurns.remove(turnId);
      if (_acceptsRuntime(epoch, lease, binding)) {
        _refreshingTerminal = false;
        notifyApplicationListeners();
      }
    }
  }

  TurnSendSelection get selection => TurnSendSelection(
        accessModeId: _accessModeId,
        reasoningEffortId: _reasoningEffortId,
        model: _modelSelection,
      );

  bool get selectionValid {
    final capabilities = _provider?.capabilities.turnSend;
    return capabilities != null && capabilities.accepts(selection);
  }

  bool get conversationBlocksSend {
    final detail = _detail;
    if (detail == null || detail.activeTurn != null) return true;
    return switch (detail.summary.status) {
      ConversationStatus.running ||
      ConversationStatus.waitingApproval ||
      ConversationStatus.waitingUserInput ||
      ConversationStatus.archived => true,
      ConversationStatus.idle || ConversationStatus.error => false,
    };
  }

  bool canSend(String text) {
    final lease = _session.runtimeLease;
    final provider = _provider;
    return lease != null &&
        _session.ownsRuntimeLease(lease) &&
        provider != null &&
        provider.status == ProviderStatus.ready &&
        provider.methods.contains('turn.send') &&
        provider.capabilities.turnSend != null &&
        _interactionAcquired &&
        !_staleCapabilities &&
        !_sending &&
        !_outcomeUnknown &&
        !_refreshingTerminal &&
        !conversationBlocksSend &&
        selectionValid &&
        text.trim().isNotEmpty;
  }

  bool get composerEnabled =>
      _detail != null &&
      _provider?.status == ProviderStatus.ready &&
      _provider?.methods.contains('turn.send') == true &&
      _interactionAcquired &&
      !_staleCapabilities &&
      !_sending &&
      !_refreshingTerminal &&
      !conversationBlocksSend &&
      !_outcomeUnknown;

  Future<bool> send(String text) async {
    if (!canSend(text)) return false;
    final lease = _session.runtimeLease;
    final provider = _provider;
    final binding = _binding;
    if (lease == null || provider == null || binding == null) return false;
    final epoch = _runtimeEpoch;
    final attempt = PendingTurnSend(
      clientRequestId: _newClientRequestId(),
      text: text,
      selection: selection,
      capabilityRevision: provider.capabilities.revision,
      route: provider.route,
      conversation: currentConversation,
    );
    _detail = _detail?.stageUserInput(
      clientRequestId: attempt.clientRequestId,
      text: attempt.text,
      createdAt: _now(),
    );
    _sending = true;
    _sendError = null;
    _pendingSend = attempt;
    notifyApplicationListeners();
    try {
      final receipt = await lease.sendTurn(
        route: attempt.route,
        conversation: attempt.conversation,
        clientRequestId: attempt.clientRequestId,
        capabilityRevision: attempt.capabilityRevision,
        text: attempt.text,
        selection: attempt.selection,
      );
      if (!_acceptsRuntime(epoch, lease, binding)) return false;
      _detail = _detail?.accept(receipt);
      _accessModeId = receipt.effectiveSelection.accessModeId;
      _reasoningEffortId = receipt.effectiveSelection.reasoningEffortId;
      _modelSelection = receipt.effectiveSelection.model;
      _pendingSend = null;
      _outcomeUnknown = false;
      _sendError = null;
      notifyApplicationListeners();
      return true;
    } catch (error) {
      if (!_acceptsRuntime(epoch, lease, binding)) return false;
      if (error is GatewayProtocolException &&
          error.code == 'stale_capability_revision') {
        _detail = _detail?.rejectStagedUserInput(attempt.clientRequestId);
        _staleCapabilities = true;
        _accessModeId = null;
        _reasoningEffortId = null;
        _modelSelection = null;
        _pendingSend = null;
        _outcomeUnknown = false;
        _sendError = 'Provider 能力已更新，正在重新连接并刷新选项。';
        notifyApplicationListeners();
        unawaited(_session.connect());
      } else if (isGatewayOutcomeUnknown(error)) {
        _outcomeUnknown = true;
        _sendError = unknownTurnOutcomeMessage;
        notifyApplicationListeners();
        unawaited(reload());
      } else {
        _detail = _detail?.rejectStagedUserInput(attempt.clientRequestId);
        _pendingSend = null;
        _outcomeUnknown = false;
        _sendError = error.toString();
        notifyApplicationListeners();
      }
      return false;
    } finally {
      if (_acceptsRuntime(epoch, lease, binding)) {
        _sending = false;
        notifyApplicationListeners();
      }
    }
  }

  void clearUnknownOutcome() {
    if (!_outcomeUnknown) return;
    _pendingSend = null;
    _outcomeUnknown = false;
    _sendError = null;
    notifyApplicationListeners();
  }

  String _newClientRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20)}';
  }

  String get composerHint {
    if (_session.runtimeLease == null) return '设备离线';
    if (_staleCapabilities) return 'Provider 能力已变化，正在刷新';
    if (_detail == null) return '正在加载会话';
    if (_outcomeUnknown) return '发送结果未知，请先刷新会话核对';
    if (_refreshingTerminal) return '正在收敛本轮结果';
    final status = _detail!.summary.status;
    if (_detail!.activeTurn != null || status == ConversationStatus.running) {
      return '当前任务仍在运行';
    }
    if (status == ConversationStatus.waitingApproval) {
      return '当前任务正在等待审批';
    }
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
    if (!selectionValid) return '请先选择可用的发送选项';
    return '继续对话';
  }

  @override
  void dispose() {
    _disposed = true;
    _runtimeEpoch++;
    _interactionTimer?.cancel();
    _session.removeListener(_sessionChanged);
    unawaited(_eventWindow?.close());
    super.dispose();
  }
}

class PendingTurnSend {
  const PendingTurnSend({
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

class _CapabilityBinding {
  const _CapabilityBinding({
    required this.generation,
    required this.lease,
    required this.route,
    required this.revision,
  });

  factory _CapabilityBinding.from(
    DeviceSessionRuntimeLease lease,
    GatewayProvider provider,
  ) =>
      _CapabilityBinding(
        generation: lease.generation,
        lease: lease,
        route: provider.route,
        revision: provider.capabilities.revision,
      );

  final int generation;
  final DeviceSessionRuntimeLease lease;
  final GatewayProviderRoute route;
  final String revision;

  @override
  bool operator ==(Object other) =>
      other is _CapabilityBinding &&
      other.generation == generation &&
      lease.sameRuntime(other.lease) &&
      other.route == route &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(
        generation,
        lease.runtimeIdentityHash,
        route,
        revision,
      );
}
