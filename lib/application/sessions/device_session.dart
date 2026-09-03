import 'dart:async';

import '../../core/domain/models.dart';
import '../errors/application_failures.dart';
import '../ports/gateway_client.dart';
import '../support/application_notifier.dart';
import '../sync/gateway_event_window.dart';
import '../../core/domain/paired_device.dart';

enum DeviceConnectionState { offline, connecting, online, failed }

class DeviceSessionRuntimeLease {
  const DeviceSessionRuntimeLease._({
    required this.generation,
    required this._client,
  });

  final int generation;
  final GatewayClient _client;

  bool sameRuntime(DeviceSessionRuntimeLease? other) =>
      other != null &&
      other.generation == generation &&
      identical(other._client, _client);

  int get runtimeIdentityHash => Object.hash(
        generation,
        identityHashCode(_client),
      );

  GatewayEventWindow openEventWindow() => _client.openEventWindow();

  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) => _client.getConversation(conversation);

  Future<ConversationInteraction> acquireInteraction(
    ConversationSummary conversation,
  ) => _client.acquireInteraction(conversation);

  Future<ConversationPage> searchConversations({
    required GatewayProviderRoute route,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  }) => _client.searchConversations(
        route: route,
        searchTerm: searchTerm,
        cursor: cursor,
        limit: limit,
      );

  Future<TurnSendReceipt> sendTurn({
    required GatewayProviderRoute route,
    required ConversationSummary conversation,
    required String clientRequestId,
    required String capabilityRevision,
    required String text,
    required TurnSendSelection selection,
  }) => _client.sendTurn(
        route: route,
        conversation: conversation,
        clientRequestId: clientRequestId,
        capabilityRevision: capabilityRevision,
        text: text,
        selection: selection,
      );

}

class DeviceSession extends ApplicationNotifier {
  DeviceSession({
    required this.device,
    required this.clientFactory,
    this.autoReconnect = true,
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
    Stream<void>? reconnectSignals,
  }) : assert(reconnectDelays.isNotEmpty) {
    _reconnectSignalSubscription = reconnectSignals?.listen(
      (_) => _handleReconnectSignal(),
    );
  }

  static const int conversationPageSize = 20;

  PairedDevice device;
  final GatewayClient Function() clientFactory;
  final bool autoReconnect;
  final List<Duration> reconnectDelays;
  GatewayClient? _client;
  GatewayEventWindow? _eventWindow;
  Timer? _reconnectTimer;
  StreamSubscription<void>? _reconnectSignalSubscription;
  final Map<GatewayProviderRoute, String?> _conversationCursors = {};
  final Set<GatewayProviderRoute> _conversationRefreshes = {};
  final Map<GatewayProviderRoute, Map<String, TurnTask>>
      _pendingConversationRefreshTurns = {};
  final Map<String, String> _livePreviewByContent = {};
  bool _isLoadingMoreConversations = false;
  String? _loadMoreError;
  int _runtimeGeneration = 0;
  int _reconnectAttempt = 0;
  bool _reconnectEnabled = false;
  bool _retryableFailure = false;
  bool _disposed = false;
  Timer? _conversationNotificationTimer;
  GatewayProviderRoute? _selectedProviderRoute;
  DeviceConnectionState connectionState = DeviceConnectionState.offline;
  GatewayHandshake? handshake;
  String? error;
  List<ConversationSummary> conversations = const [];

  DeviceSessionRuntimeLease? get runtimeLease {
    final currentClient = _client;
    if (connectionState != DeviceConnectionState.online ||
        currentClient == null) {
      return null;
    }
    return DeviceSessionRuntimeLease._(
      generation: _runtimeGeneration,
      client: currentClient,
    );
  }
  bool ownsRuntimeLease(DeviceSessionRuntimeLease lease) =>
      connectionState == DeviceConnectionState.online &&
      _ownsRuntime(lease.generation, lease._client);

  Future<ConversationReadState> markConversationRead(
    ConversationSummary conversation,
  ) async {
    final client = _client;
    if (client == null || client is! ConversationReadGatewayClient) {
      return conversation.readState;
    }
    final readClient = client as ConversationReadGatewayClient;
    final generation = _runtimeGeneration;
    final state = await readClient.markConversationRead(conversation);
    if (_ownsRuntime(generation, client)) {
      _setConversationReadState(conversation, state);
      _notifyListenersImmediately();
    }
    return state;
  }
  List<GatewayProvider> get conversationListProviders => handshake?.providers
          .where((provider) => provider.methods.contains('conversation.list'))
          .toList(growable: false) ??
      const [];
  List<GatewayProvider> get conversationSearchProviders => handshake?.providers
          .where((provider) => provider.methods.contains('conversation.search'))
          .toList(growable: false) ??
      const [];
  GatewayProvider? get selectedProvider {
    final providers = handshake?.providers ?? const <GatewayProvider>[];
    if (providers.isEmpty) return null;
    final selectedRoute = _selectedProviderRoute;
    if (selectedRoute != null) {
      for (final provider in providers) {
        if (provider.route == selectedRoute) return provider;
      }
    }
    return providers.first;
  }
  List<ConversationSummary> get selectedProviderConversations {
    final provider = selectedProvider;
    if (provider == null) return conversations;
    return conversations
        .where((conversation) => conversationBelongsToProvider(
              conversation,
              provider,
            ))
        .toList(growable: false);
  }
  bool get canLoadMoreSelectedProviderConversations {
    final provider = selectedProvider;
    return provider == null
        ? canLoadMoreConversations
        : connectionState == DeviceConnectionState.online &&
            _conversationCursors[provider.route] != null;
  }
  String get selectedProviderConversationCountLabel =>
      '${selectedProviderConversations.length}'
      '${canLoadMoreSelectedProviderConversations ? '+' : ''}';

  void selectProvider(GatewayProvider provider) {
    final providers = handshake?.providers ?? const <GatewayProvider>[];
    if (!providers.any((item) => item.route == provider.route)) return;
    if (_selectedProviderRoute == provider.route) return;
    _selectedProviderRoute = provider.route;
    _loadMoreError = null;
    _notifyListenersImmediately();
  }
  GatewayProvider? providerForConversation(ConversationSummary conversation) {
    final route = conversation.resource?.route;
    if (route == null) return null;
    final providers = handshake?.providers ?? const <GatewayProvider>[];
    for (final provider in providers) {
      if (provider.route == route) {
        return provider;
      }
    }
    return null;
  }
  bool conversationBelongsToProvider(
    ConversationSummary conversation,
    GatewayProvider provider,
  ) {
    final routedProvider = providerForConversation(conversation);
    return routedProvider?.route == provider.route ||
        routedProvider == null && conversation.providerId == provider.id;
  }
  bool get canLoadMoreConversations =>
      connectionState == DeviceConnectionState.online &&
      _conversationCursors.values.any((cursor) => cursor != null);
  String get conversationCountLabel =>
      '${conversations.length}${canLoadMoreConversations ? '+' : ''}';
  bool get isLoadingMoreConversations => _isLoadingMoreConversations;
  String? get loadMoreError => _loadMoreError;

  Future<void> connect() {
    _reconnectEnabled = autoReconnect;
    _retryableFailure = false;
    _cancelReconnect(resetAttempt: true);
    return _connect();
  }

  Future<void> _connect() async {
    if (connectionState == DeviceConnectionState.connecting) return;
    final oldWindow = _eventWindow;
    final oldClient = _client;
    final generation = ++_runtimeGeneration;
    _eventWindow = null;
    _client = null;
    handshake = null;
    _resetConversationPagination();
    connectionState = DeviceConnectionState.connecting;
    error = null;
    _notifyListenersImmediately();
    try {
      await oldWindow?.close();
    } catch (_) {}
    try {
      await oldClient?.close();
    } catch (_) {}
    if (generation != _runtimeGeneration) return;
    try {
      final client = clientFactory();
      _client = client;
      final window = client.openEventWindow();
      _eventWindow = window;
      final connectedHandshake = await client.connect();
      if (!_ownsRuntime(generation, client)) return;
      handshake = connectedHandshake;
      final providers = connectedHandshake.providers;
      if (!providers.any((provider) => provider.route == _selectedProviderRoute)) {
        _selectedProviderRoute = providers.isEmpty ? null : providers.first.route;
      }
      final hostDescriptor = connectedHandshake.deviceDescriptor;
      if (hostDescriptor != null) {
        device = device.withDescriptor(hostDescriptor);
      }
      var snapshotCursor = connectedHandshake.eventCursor;
      var isFirstPage = true;
      for (final provider in conversationListProviders) {
        final page = await client.listConversations(
          route: provider.route,
          limit: conversationPageSize,
        );
        if (!_ownsRuntime(generation, client)) return;
        if (isFirstPage) {
          snapshotCursor = page.snapshotCursor;
          isFirstPage = false;
        }
        conversations = mergeRoutedConversations(
          conversations,
          page.conversations,
        );
        _conversationCursors[provider.route] = page.nextCursor;
      }
      window.install(
        baselineCursor: connectedHandshake.eventCursor,
        snapshotCursor: snapshotCursor,
        onEvent: (event) {
          if (_ownsRuntime(generation, client)) {
            _applyEvent(event);
          }
        },
        onError: (Object value, StackTrace _) {
          unawaited(
            _failRuntime(
              '事件流异常：$value',
              cause: value,
              generation: generation,
              client: client,
            ),
          );
        },
      );
      connectionState = DeviceConnectionState.online;
      _retryableFailure = false;
      _reconnectAttempt = 0;
      _notifyListenersImmediately();
    } catch (value) {
      if (generation != _runtimeGeneration) return;
      final connectionError = value.toString();
      final window = _eventWindow;
      final client = _client;
      final failureGeneration = ++_runtimeGeneration;
      _eventWindow = null;
      _client = null;
      handshake = null;
      _resetConversationPagination();
      error = connectionError;
      _retryableFailure = isRetryableGatewayFailure(value);
      connectionState = DeviceConnectionState.failed;
      _notifyListenersImmediately();
      try {
        await window?.close();
      } catch (_) {}
      try {
        await client?.close();
      } catch (_) {}
      if (_retryableFailure) {
        _scheduleReconnect(failureGeneration);
      }
    }
  }

  void _scheduleReconnect(int generation) {
    if (!_canReconnect(generation) || _reconnectTimer != null) return;
    final delayIndex = _reconnectAttempt.clamp(0, reconnectDelays.length - 1);
    final delay = reconnectDelays[delayIndex];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_canReconnect(generation)) unawaited(_connect());
    });
  }

  bool _canReconnect(int generation) =>
      generation == _runtimeGeneration &&
      connectionState == DeviceConnectionState.failed &&
      _reconnectEnabled &&
      _retryableFailure &&
      !_disposed;

  void _handleReconnectSignal() {
    if (connectionState != DeviceConnectionState.failed ||
        !_reconnectEnabled ||
        !_retryableFailure ||
        _disposed) {
      return;
    }
    _cancelReconnect();
    unawaited(_connect());
  }

  void _cancelReconnect({bool resetAttempt = false}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (resetAttempt) _reconnectAttempt = 0;
  }

  Future<void> loadMoreConversations({GatewayProviderRoute? route}) async {
    final client = _client;
    final pendingRoutes = _conversationCursors.entries
        .where((entry) =>
            entry.value != null && (route == null || entry.key == route))
        .toList(growable: false);
    if (connectionState != DeviceConnectionState.online ||
        client == null ||
        pendingRoutes.isEmpty ||
        _isLoadingMoreConversations) {
      return;
    }

    final generation = _runtimeGeneration;
    _isLoadingMoreConversations = true;
    _loadMoreError = null;
    _notifyListenersImmediately();
    try {
      final pages = await Future.wait([
        for (final entry in pendingRoutes)
          client.listConversations(
            route: entry.key,
            cursor: entry.value,
            limit: conversationPageSize,
          ),
      ]);
      if (!_ownsRuntime(generation, client)) return;
      for (var index = 0; index < pages.length; index++) {
        final page = pages[index];
        conversations = mergeRoutedConversations(
          conversations,
          page.conversations,
        );
        _conversationCursors[pendingRoutes[index].key] = page.nextCursor;
      }
      _loadMoreError = null;
    } catch (value) {
      if (!_ownsRuntime(generation, client)) return;
      _loadMoreError = value.toString();
    } finally {
      if (_ownsRuntime(generation, client)) {
        _isLoadingMoreConversations = false;
        _notifyListenersImmediately();
      }
    }
  }

  Future<void> loadMoreSelectedProviderConversations() =>
      loadMoreConversations(route: selectedProvider?.route);

  Future<ConversationSummary> createConversation({
    required GatewayProvider provider,
    String? title,
    String? workspaceRoot,
    String? permissionLevel,
    String? model,
    String? reasoningEffort,
    String? workspaceMode,
  }) async {
    final lease = runtimeLease;
    if (lease == null ||
        provider.status != ProviderStatus.ready ||
        !provider.methods.contains('conversation.create')) {
      throw StateError('当前 Provider 不支持新建会话');
    }
    final createCapabilities = provider.capabilities.conversationCreate;
    final capabilities = createCapabilities?.selection ??
        provider.capabilities.turnSend;
    final accessMode = capabilities?.accessMode;
    final effectivePermissionLevel = permissionLevel ??
        accessMode?.defaultId ??
        (accessMode?.availableOptions.isNotEmpty == true
            ? accessMode!.availableOptions.first.id
            : PermissionLevel.workspaceWrite);
    final reasoning = capabilities?.reasoningEffort;
    final effectiveReasoningEffort = reasoningEffort ??
        reasoning?.defaultId ??
        (reasoning?.availableOptions.isNotEmpty == true
            ? reasoning!.availableOptions.first.id
            : null);
    final modelCatalog = capabilities?.modelCatalog;
    final modelSelection = modelCatalog?.defaultSelection ??
        (modelCatalog?.availableSelections.isNotEmpty == true
            ? modelCatalog!.availableSelections.first
            : null);
    final effectiveModel = model ?? modelCatalog?.modelFor(modelSelection)?.id;
    final workspaceModes = createCapabilities?.workspaceMode;
    final effectiveWorkspaceMode = workspaceMode ??
        workspaceModes?.defaultId ??
        (workspaceModes?.availableOptions.isNotEmpty == true
            ? workspaceModes!.availableOptions.first.id
            : null);
    final conversation = await lease._client.createConversation(
      route: provider.route,
      title: title?.trim().isEmpty == true ? null : title?.trim(),
      permissionLevel: effectivePermissionLevel,
      model: effectiveModel,
      reasoningEffort: effectiveReasoningEffort,
      workspaceRoot: workspaceRoot?.trim().isEmpty == true
          ? null
          : workspaceRoot?.trim(),
      workspaceMode: effectiveWorkspaceMode,
    );
    if (!ownsRuntimeLease(lease)) {
      throw StateError('连接已变化，请重新新建会话');
    }
    _upsertEventConversation(conversation);
    _notifyListenersImmediately();
    return conversation;
  }

  bool _ownsRuntime(int generation, GatewayClient client) =>
      generation == _runtimeGeneration && identical(_client, client);

  void _resetConversationPagination() {
    conversations = const [];
    _conversationCursors.clear();
    _conversationRefreshes.clear();
    _pendingConversationRefreshTurns.clear();
    _livePreviewByContent.clear();
    _isLoadingMoreConversations = false;
    _loadMoreError = null;
  }

  Future<void> _failRuntime(
    String message, {
    required Object cause,
    required int generation,
    required GatewayClient client,
  }) async {
    if (!_ownsRuntime(generation, client)) return;
    final window = _eventWindow;
    final failureGeneration = ++_runtimeGeneration;
    _eventWindow = null;
    _client = null;
    handshake = null;
    _resetConversationPagination();
    error = message;
    _retryableFailure = isRetryableGatewayFailure(cause);
    connectionState = DeviceConnectionState.failed;
    _notifyListenersImmediately();
    try {
      await window?.close();
    } catch (_) {}
    try {
      await client.close();
    } catch (_) {}
    if (_retryableFailure) {
      _scheduleReconnect(failureGeneration);
    }
  }

  void _applyEvent(GatewayEvent event) {
    if (event is GatewayProviderChangedEvent) {
      final currentHandshake = handshake;
      if (currentHandshake == null) return;
      final providers = [...currentHandshake.providers];
      final index = providers.indexWhere(
        (provider) => provider.route == event.provider.route,
      );
      if (index == -1) return;
      providers[index] = event.provider;
      handshake = currentHandshake.withProviders(providers);
      _notifyListenersImmediately();
      return;
    }
    if (event is ConversationUpsertedEvent) {
      _upsertEventConversation(event.conversation);
      _notifyListenersImmediately();
      return;
    }
    if (event is ConversationActivityChangedEvent) {
      final index = conversations.indexWhere(
        (conversation) =>
            conversationRoutingKey(conversation) == event.conversationId ||
            conversation.id == event.conversationId,
      );
      if (index == -1) return;
      final current = conversations[index];
      conversations = [
        for (var itemIndex = 0;
            itemIndex < conversations.length;
            itemIndex++)
          if (itemIndex == index)
            current.withReadState(ConversationReadState(
              unread: true,
              activityVersion: event.activityVersion,
            ))
          else
            conversations[itemIndex],
      ];
      _notifyListenersImmediately();
      return;
    }
    if (event is TurnOutputDeltaEvent) {
      if (_applyDeltaToConversation(event)) {
        _scheduleConversationNotification();
      }
      return;
    }
    if (event is! TurnUpsertedEvent) return;
    if (_applyTurnToConversation(event.turn)) {
      _notifyListenersImmediately();
      return;
    }
    final route = _routeForTurn(event.turn);
    if (route != null) {
      unawaited(_refreshConversationsForEvent(route, event.turn));
    }
  }

  void _upsertEventConversation(ConversationSummary incoming) {
    final key = conversationRoutingKey(incoming);
    ConversationSummary? current;
    for (final conversation in conversations) {
      if (conversationRoutingKey(conversation) == key) {
        current = conversation;
        break;
      }
    }
    final eventConversation = current == null
        ? incoming
        : incoming.withReadState(current.readState);
    // Event cursors define stream order. Provider timestamps can lag metadata
    // notifications, so accept the event while keeping list order monotonic.
    final next = current != null && current.updatedAt.isAfter(incoming.updatedAt)
        ? ConversationSummary(
            id: eventConversation.id,
            providerId: eventConversation.providerId,
            title: eventConversation.title,
            preview: eventConversation.preview,
            status: eventConversation.status,
            permissionLevel: eventConversation.permissionLevel,
            model: eventConversation.model,
            reasoningEffort: eventConversation.reasoningEffort,
            workspaceRoot: eventConversation.workspaceRoot,
            createdAt: eventConversation.createdAt,
            updatedAt: current.updatedAt,
            activeTurn: eventConversation.activeTurn,
            turnSendSelection: eventConversation.turnSendSelection,
            resource: eventConversation.resource,
            readState: eventConversation.readState,
          )
        : eventConversation;
    conversations = sortRecentConversations([
      for (final conversation in conversations)
        if (conversationRoutingKey(conversation) != key) conversation,
      next,
    ]);
  }

  bool _applyTurnToConversation(TurnTask turn) {
    final turnConversationKey = turn.conversationResource?.key;
    final index = conversations.indexWhere(
      (conversation) =>
          conversationRoutingKey(conversation) == turn.conversationId ||
          conversation.id == turn.conversationId ||
          turnConversationKey != null &&
              conversation.resource?.key == turnConversationKey,
    );
    if (index == -1) return false;
    final current = conversations[index];
    if (current.updatedAt.isAfter(turn.updatedAt)) return true;
    final next = ConversationSummary(
      id: current.id,
      providerId: current.providerId,
      title: current.title,
      preview: current.preview,
      status: switch (turn.status) {
        TurnStatus.queued || TurnStatus.running => ConversationStatus.running,
        TurnStatus.waitingApproval => ConversationStatus.waitingApproval,
        TurnStatus.failed => ConversationStatus.error,
        TurnStatus.completed || TurnStatus.interrupted => ConversationStatus.idle,
      },
      permissionLevel: current.permissionLevel,
      model: current.model,
      reasoningEffort: current.reasoningEffort,
      workspaceRoot: current.workspaceRoot,
      createdAt: current.createdAt,
      updatedAt: turn.updatedAt,
      activeTurn: turn.status.isTerminal ? null : turn,
      turnSendSelection: current.turnSendSelection,
      resource: current.resource,
      readState: current.readState,
    );
    conversations = sortRecentConversations([
      for (var itemIndex = 0; itemIndex < conversations.length; itemIndex++)
        if (itemIndex == index) next else conversations[itemIndex],
    ]);
    return true;
  }

  bool _applyDeltaToConversation(TurnOutputDeltaEvent event) {
    if (event.kind != 'text' || event.delta.isEmpty) return false;
    final index = conversations.indexWhere(
      (conversation) =>
          conversationRoutingKey(conversation) == event.conversationId ||
          conversation.id == event.conversationId,
    );
    if (index == -1) return false;
    final contentKey = '${event.conversationId}\u0000${event.contentId}';
    final complete = '${_livePreviewByContent[contentKey] ?? ''}${event.delta}';
    _livePreviewByContent[contentKey] = _tailRunes(complete, 4096);
    final current = conversations[index];
    final preview = _tailRunes(complete, 240);
    final next = ConversationSummary(
      id: current.id,
      providerId: current.providerId,
      title: current.title,
      preview: preview,
      status: current.status,
      permissionLevel: current.permissionLevel,
      model: current.model,
      reasoningEffort: current.reasoningEffort,
      workspaceRoot: current.workspaceRoot,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
      activeTurn: current.activeTurn,
      turnSendSelection: current.turnSendSelection,
      resource: current.resource,
      readState: current.readState,
    );
    conversations = [
      for (var itemIndex = 0; itemIndex < conversations.length; itemIndex++)
        if (itemIndex == index) next else conversations[itemIndex],
    ];
    return true;
  }

  GatewayProviderRoute? _routeForTurn(TurnTask turn) {
    return (turn.conversationResource ?? turn.resource)?.route;
  }

  void _setConversationReadState(
    ConversationSummary conversation,
    ConversationReadState state,
  ) {
    final key = conversationRoutingKey(conversation);
    conversations = [
      for (final current in conversations)
        if (conversationRoutingKey(current) == key)
          current.withReadState(current.readState.merge(state))
        else
          current,
    ];
  }

  Future<void> _refreshConversationsForEvent(
    GatewayProviderRoute route,
    TurnTask turn,
  ) async {
    final pending = _pendingConversationRefreshTurns.putIfAbsent(
      route,
      () => {},
    );
    final current = pending[turn.id];
    if (current == null || turn.updatedAt.isAfter(current.updatedAt)) {
      pending[turn.id] = turn;
    }
    if (!_conversationRefreshes.add(route)) return;
    var continuePending = true;
    try {
      while (true) {
        final client = _client;
        final generation = _runtimeGeneration;
        if (client == null) return;
        final batch = _pendingConversationRefreshTurns.remove(route);
        if (batch == null || batch.isEmpty) return;
        try {
          final page = await client.listConversations(
            route: route,
            limit: conversationPageSize,
          );
          if (!_ownsRuntime(generation, client)) return;
          conversations = mergeRoutedConversations(
            conversations,
            page.conversations,
          );
          for (final pendingTurn in batch.values) {
            _applyTurnToConversation(pendingTurn);
          }
          _notifyListenersImmediately();
        } catch (_) {
          continuePending = false;
          final retry = _pendingConversationRefreshTurns.putIfAbsent(
            route,
            () => {},
          );
          for (final pendingTurn in batch.values) {
            retry.putIfAbsent(pendingTurn.id, () => pendingTurn);
          }
          return;
        }
      }
    } finally {
      _conversationRefreshes.remove(route);
      if (continuePending &&
          connectionState == DeviceConnectionState.online &&
          _client != null &&
          _pendingConversationRefreshTurns[route]?.isNotEmpty == true) {
        final next = _pendingConversationRefreshTurns[route]!.values.first;
        unawaited(_refreshConversationsForEvent(route, next));
      }
    }
  }

  Future<void> disconnect() async {
    _reconnectEnabled = false;
    _retryableFailure = false;
    _cancelReconnect(resetAttempt: true);
    final window = _eventWindow;
    final client = _client;
    _runtimeGeneration++;
    _eventWindow = null;
    _client = null;
    handshake = null;
    error = null;
    _resetConversationPagination();
    connectionState = DeviceConnectionState.offline;
    _notifyListenersImmediately();
    try {
      await window?.close();
    } catch (_) {}
    try {
      await client?.close();
    } catch (_) {}
  }

  void _scheduleConversationNotification() {
    if (_disposed || _conversationNotificationTimer != null) return;
    _conversationNotificationTimer = Timer(const Duration(milliseconds: 1), () {
      _conversationNotificationTimer = null;
      if (!_disposed) notifyApplicationListeners();
    });
  }

  void _notifyListenersImmediately() {
    if (_disposed) return;
    _cancelConversationNotification();
    notifyApplicationListeners();
  }

  void _cancelConversationNotification() {
    _conversationNotificationTimer?.cancel();
    _conversationNotificationTimer = null;
  }

  @override
  void dispose() {
    _cancelConversationNotification();
    _disposed = true;
    _reconnectEnabled = false;
    _retryableFailure = false;
    _cancelReconnect(resetAttempt: true);
    unawaited(_reconnectSignalSubscription?.cancel());
    _reconnectSignalSubscription = null;
    _runtimeGeneration++;
    final window = _eventWindow;
    final client = _client;
    _eventWindow = null;
    _client = null;
    unawaited(window?.close());
    if (client != null) unawaited(client.close());
    super.dispose();
  }
}

List<ConversationSummary> sortRecentConversations(
  Iterable<ConversationSummary> values,
) {
  return values.toList(growable: false)
    ..sort(_compareRecentConversations);
}

int _compareRecentConversations(
  ConversationSummary left,
  ConversationSummary right,
) {
  final updatedAt = right.updatedAt.compareTo(left.updatedAt);
  if (updatedAt != 0) return updatedAt;
  return conversationRoutingKey(left).compareTo(conversationRoutingKey(right));
}

List<ConversationSummary> mergeRoutedConversations(
  Iterable<ConversationSummary> existing,
  Iterable<ConversationSummary> incoming,
) => sortRecentConversations(
  deduplicateRoutedConversations([...existing, ...incoming]),
);

Map<String, List<ConversationSummary>> groupConversationsByWorkspace(
  Iterable<ConversationSummary> values,
) {
  final groups = <String, List<ConversationSummary>>{};
  for (final conversation in values) {
    final root = conversation.workspaceRoot;
    if (root == null || root.trim().isEmpty) continue;
    groups.putIfAbsent(root, () => []).add(conversation);
  }
  for (final conversations in groups.values) {
    conversations.sort(_compareRecentConversations);
  }
  return Map.fromEntries(
    groups.entries.toList()
      ..sort((left, right) {
        final updated = right.value.first.updatedAt.compareTo(left.value.first.updatedAt);
        return updated != 0 ? updated : left.key.compareTo(right.key);
      }),
  );
}

class ConversationProject {
  const ConversationProject({
    required this.hostDeviceId,
    required this.workspaceRoot,
    required this.conversations,
  });

  final String hostDeviceId;
  final String workspaceRoot;
  final List<ConversationSummary> conversations;

  String get key => '$hostDeviceId\u0000$workspaceRoot';
}

List<ConversationProject> groupConversationsByProject({
  required String hostDeviceId,
  required Iterable<ConversationSummary> values,
}) {
  final groups = groupConversationsByWorkspace(
    deduplicateRoutedConversations(values),
  );
  return groups.entries
      .map((entry) => ConversationProject(
            hostDeviceId: hostDeviceId,
            workspaceRoot: entry.key,
            conversations: entry.value,
          ))
      .toList(growable: false);
}

Iterable<ConversationSummary> deduplicateRoutedConversations(
  Iterable<ConversationSummary> values,
) {
  final conversations = <String, ConversationSummary>{};
  for (final conversation in values) {
    final key = conversationRoutingKey(conversation);
    final current = conversations[key];
    // Callers pass the older projection first, so equal timestamps must let the
    // later snapshot refresh metadata such as an asynchronously generated title.
    if (current == null ||
        !conversation.updatedAt.isBefore(current.updatedAt)) {
      conversations[key] = conversation;
    }
  }
  return conversations.values;
}

String conversationRoutingKey(ConversationSummary conversation) {
  final resource = conversation.resource;
  if (resource != null) return resource.key;
  return '${conversation.providerId}\u0000${conversation.id}';
}

String _tailRunes(String value, int limit) {
  final runes = value.runes.toList(growable: false);
  if (runes.length <= limit) return value;
  return String.fromCharCodes(runes.skip(runes.length - limit));
}

Future<int> replaceDeviceSession(
  List<DeviceSession> sessions,
  DeviceSession replacement,
) async {
  final index = sessions.indexWhere(
    (session) => session.device.deviceId == replacement.device.deviceId,
  );
  if (index == -1) {
    sessions.add(replacement);
    return sessions.length - 1;
  }
  final previous = sessions[index];
  sessions[index] = replacement;
  await previous.disconnect();
  previous.dispose();
  return index;
}
