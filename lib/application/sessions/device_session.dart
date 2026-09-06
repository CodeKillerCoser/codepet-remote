import 'dart:async';

import '../conversations/conversation_message_cache.dart';

import '../../core/domain/models.dart';
import '../errors/application_failures.dart';
import '../ports/application_log.dart';
import '../ports/trace_recorder.dart';
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

  Future<ConversationSnapshot> getConversationPage(
    ConversationSummary conversation, {
    required String cursor,
  }) => (_client as ConversationHistoryGatewayClient)
      .getConversationPage(conversation, cursor: cursor);

  Future<ConversationInteraction> acquireInteraction(
    ConversationSummary conversation,
  ) => _client.acquireInteraction(conversation);

  bool get supportsConversationResume => _client is ConversationResumeGatewayClient;

  Future<ConversationResumeResult> resumeConversation(
    ConversationSummary conversation,
  ) => (_client as ConversationResumeGatewayClient).resumeConversation(conversation);

  Future<ConversationPage> searchConversations({
    required String providerId,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  }) => _client.searchConversations(
        providerId: providerId,
        searchTerm: searchTerm,
        cursor: cursor,
        limit: limit,
      );

  Future<TurnSendReceipt> sendTurn({
    required String providerId,
    required ConversationSummary conversation,
    required String clientRequestId,
    required String capabilityRevision,
    required String text,
    required TurnSendSelection selection,
  }) => _client.sendTurn(
        providerId: providerId,
        conversation: conversation,
        clientRequestId: clientRequestId,
        capabilityRevision: capabilityRevision,
        text: text,
        selection: selection,
      );

  bool get supportsConversationControl =>
      _client is ConversationControlGatewayClient;

  Future<TurnTask> interruptTurn({
    required ConversationSummary conversation,
    required TurnTask turn,
  }) => (_client as ConversationControlGatewayClient)
      .interruptTurn(conversation: conversation, turn: turn);

  Future<GatewayMessage> resolveApproval({
    required GatewayMessage approval,
    required ApprovalDecision decision,
  }) => (_client as ConversationControlGatewayClient)
      .resolveApproval(approval: approval, decision: decision);

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
    this.logger = const NoopApplicationLog(),
    this.traceRecorder = const NoopTraceRecorder(),
  }) : assert(reconnectDelays.isNotEmpty) {
    _reconnectSignalSubscription = reconnectSignals?.listen(
      (_) => _handleReconnectSignal(),
    );
  }

  final messageCache = ConversationMessageCache();

  static const int conversationPageSize = 20;

  PairedDevice device;
  final GatewayClient Function() clientFactory;
  final bool autoReconnect;
  final List<Duration> reconnectDelays;
  final ApplicationLog logger;
  final TraceRecorder traceRecorder;
  GatewayClient? _client;
  GatewayEventWindow? _eventWindow;
  Timer? _reconnectTimer;
  StreamSubscription<void>? _reconnectSignalSubscription;
  final Map<_ConversationListScope, String?> _conversationCursors = {};
  final Set<_ConversationListScope> _loadedConversationScopes = {};
  final Set<_ConversationListScope> _loadingProjectConversationScopes = {};
  final Map<String, String?> _projectCursors = {};
  final Set<String> _projectRefreshes = {};
  final Set<String> _pendingProjectRefreshes = {};
  final Set<String> _conversationRefreshes = {};
  final Map<String, Map<String, TurnTask>>
      _pendingConversationRefreshTurns = {};
  final Map<String, String> _livePreviewByContent = {};
  final Map<String, DateTime> _backgroundWarningTimes = {};
  final Map<String, int> _suppressedBackgroundWarnings = {};
  bool _isLoadingMoreConversations = false;
  String? _loadMoreError;
  bool _isLoadingMoreProjects = false;
  String? _loadMoreProjectsError;
  int _projectRequestSequence = 0;
  int _runtimeGeneration = 0;
  int _reconnectAttempt = 0;
  bool _hasStartedConnection = false;
  bool _isReconnectAttempt = false;
  bool _reconnectEnabled = false;
  bool _retryableFailure = false;
  bool _disposed = false;
  Timer? _conversationNotificationTimer;
  String? _selectedProviderId;
  DeviceConnectionState connectionState = DeviceConnectionState.offline;
  GatewayHandshake? handshake;
  String? error;
  List<ConversationSummary> conversations = const [];
  List<GatewayProject> projects = const [];

  bool get isReconnecting =>
      connectionState == DeviceConnectionState.connecting &&
      _isReconnectAttempt;
  DeviceDescriptor? get deviceDescriptor =>
      handshake?.deviceDescriptor ?? device.descriptor;
  String get displayDeviceName => device.effectiveName;
  String get displaySystemLabel {
    final descriptor = deviceDescriptor;
    if (descriptor == null) return '系统未知';
    return '${descriptor.operatingSystem} ${descriptor.systemVersion}';
  }

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
  List<GatewayProvider> get projectListProviders => handshake?.providers
          .where((provider) => provider.methods.contains('project.list'))
          .toList(growable: false) ??
      const [];
  GatewayProvider? get selectedProvider {
    final providers = handshake?.providers ?? const <GatewayProvider>[];
    if (providers.isEmpty) return null;
    final selectedId = _selectedProviderId;
    if (selectedId != null) {
      for (final provider in providers) {
        if (provider.id == selectedId) return provider;
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
  bool get selectedProviderSupportsProjects =>
      selectedProvider?.methods.contains('project.list') == true;
  List<GatewayProject> get selectedProviderProjects {
    final providerId = selectedProvider?.id;
    if (providerId == null) return const [];
    return projects
        .where((project) => project.resource.providerId == providerId)
        .toList(growable: false);
  }
  List<ConversationSummary> get selectedProviderRecentConversations {
    final provider = selectedProvider;
    if (provider == null) return conversations;
    final values = selectedProviderConversations;
    return provider.methods.contains('project.list')
        ? values
            .where((conversation) => conversation.project == null)
            .toList(growable: false)
        : values;
  }
  List<ConversationSummary> conversationsForProject(GatewayProject project) =>
      sortRecentConversations(
        selectedProviderConversations.where(
          (conversation) => conversation.project == project.resource,
        ),
      );
  bool hasLoadedProjectConversations(GatewayProject project) =>
      _loadedConversationScopes.contains(
        _ConversationListScope.project(project.resource),
      );
  bool isLoadingProjectConversations(GatewayProject project) =>
      _loadingProjectConversationScopes.contains(
        _ConversationListScope.project(project.resource),
      );
  String? projectConversationCountLabel(GatewayProject project) {
    if (!hasLoadedProjectConversations(project)) return null;
    final count = conversationsForProject(project).length;
    return '$count${canLoadMoreProjectConversations(project) ? '+' : ''}';
  }
  bool get canLoadMoreSelectedProviderConversations {
    final provider = selectedProvider;
    if (provider == null) return false;
    final scope = _recentScope(provider);
    return connectionState == DeviceConnectionState.online &&
        _conversationCursors[scope] != null;
  }
  String get selectedProviderConversationCountLabel =>
      '${selectedProviderRecentConversations.length}'
      '${canLoadMoreSelectedProviderConversations ? '+' : ''}';

  bool get canLoadMoreSelectedProviderProjects {
    final provider = selectedProvider;
    return provider != null &&
        connectionState == DeviceConnectionState.online &&
        _projectCursors[provider.id] != null;
  }
  bool get isLoadingMoreProjects => _isLoadingMoreProjects;
  String? get loadMoreProjectsError => _loadMoreProjectsError;

  void selectProvider(GatewayProvider provider) {
    final providers = handshake?.providers ?? const <GatewayProvider>[];
    if (!providers.any((item) => item.id == provider.id)) return;
    if (_selectedProviderId == provider.id) return;
    _selectedProviderId = provider.id;
    _loadMoreError = null;
    _notifyListenersImmediately();
  }
  GatewayProvider? providerForConversation(ConversationSummary conversation) {
    final providerId = conversation.resource?.providerId;
    if (providerId == null) return null;
    final providers = handshake?.providers ?? const <GatewayProvider>[];
    for (final provider in providers) {
      if (provider.id == providerId) {
        return provider;
      }
    }
    return null;
  }
  GatewayProvider? _providerForId(String providerId) {
    for (final provider in handshake?.providers ?? const <GatewayProvider>[]) {
      if (provider.id == providerId) return provider;
    }
    return null;
  }
  _ConversationListScope _recentScope(GatewayProvider provider) =>
      provider.methods.contains('project.list')
          ? _ConversationListScope.standalone(provider.id)
          : _ConversationListScope.all(provider.id);
  _ConversationListScope _recentScopeForProvider(String providerId) {
    final provider = _providerForId(providerId);
    return provider == null
        ? _ConversationListScope.all(providerId)
        : _recentScope(provider);
  }
  bool conversationBelongsToProvider(
    ConversationSummary conversation,
    GatewayProvider provider,
  ) {
    final routedProvider = providerForConversation(conversation);
    return routedProvider?.id == provider.id ||
        routedProvider == null && conversation.providerId == provider.id;
  }
  bool get canLoadMoreConversations =>
      connectionState == DeviceConnectionState.online &&
      _conversationCursors.values.any((cursor) => cursor != null);
  String get conversationCountLabel =>
      '${conversations.length}${canLoadMoreConversations ? '+' : ''}';
  bool get isLoadingMoreConversations =>
      _isLoadingMoreConversations ||
      _loadingProjectConversationScopes.isNotEmpty;
  String? get loadMoreError => _loadMoreError;

  Future<void> connect() {
    logger.info('Connection requested for device ${device.deviceId}');
    _reconnectEnabled = autoReconnect;
    _retryableFailure = false;
    _cancelReconnect(resetAttempt: true);
    return _connect();
  }

  StreamSubscription<List<GatewayProvider>>? _providerStatusSubscription;

  Future<void> _connect() async {
    if (connectionState == DeviceConnectionState.connecting) return;
    _isReconnectAttempt = _hasStartedConnection;
    _hasStartedConnection = true;
    logger.info(
      'Starting connection attempt for device ${device.deviceId} '
      '(attempt ${_reconnectAttempt + 1})',
    );
    final stopwatch = Stopwatch()..start();
    final oldProviderSubscription = _providerStatusSubscription;
    _providerStatusSubscription = null;
    final oldWindow = _eventWindow;
    final oldClient = _client;
    final generation = ++_runtimeGeneration;
    _eventWindow = null;
    _client = null;
    messageCache.clear();
    handshake = null;
    _resetConversationPagination();
    connectionState = DeviceConnectionState.connecting;
    error = null;
    _notifyListenersImmediately();
    await oldProviderSubscription?.cancel();
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
      final providers = await Future.wait([
        for (final provider in connectedHandshake.providers)
          provider.capabilitiesLoaded
              ? Future.value(provider)
              : client.describeProvider(provider.id),
      ]);
      if (!_ownsRuntime(generation, client)) return;
      handshake = connectedHandshake.withProviders(providers);
      if (client is ProviderSnapshotGatewayClient) {
        _providerStatusSubscription = (client as ProviderSnapshotGatewayClient).providerSnapshots.listen((snapshot) {
          if (!_ownsRuntime(generation, client)) return;
          final current = handshake;
          if (current == null) return;
          final ids = snapshot.map((p) => p.id).toSet();
          handshake = current.withProviders(current.providers.where((p) => ids.contains(p.id)).toList());
          for (final provider in snapshot) {
            _applyProviderUpdate(provider);
          }
          if (!ids.contains(_selectedProviderId)) _selectedProviderId = snapshot.isEmpty ? null : snapshot.first.id;
          _notifyListenersImmediately();
        });
      }

      if (!providers.any((provider) => provider.id == _selectedProviderId)) {
        _selectedProviderId = providers.isEmpty ? null : providers.first.id;
      }
      device = device.withDescriptor(connectedHandshake.deviceDescriptor);
      var snapshotCursor = connectedHandshake.eventCursor;
      var hasSnapshot = false;
      void acceptSnapshot(String cursor) {
        if (hasSnapshot) return;
        snapshotCursor = cursor;
        hasSnapshot = true;
      }
      final projectClient = client is ProjectGatewayClient
          ? client as ProjectGatewayClient
          : null;
      for (final provider in projectListProviders.where((p) => p.isAvailable)) {
        if (projectClient == null) {
          throw UnsupportedError(
            'Gateway SDK adapter does not implement advertised project methods',
          );
        }
        final page = await projectClient.listProjects(
          providerId: provider.id,
          limit: conversationPageSize,
        );
        if (!_ownsRuntime(generation, client)) return;
        acceptSnapshot(page.snapshotCursor);
        projects = mergeRoutedProjects(projects, page.projects);
        _projectCursors[provider.id] = page.nextCursor;
      }
      for (final provider in conversationListProviders.where((p) => p.isAvailable)) {
        final scope = _recentScope(provider);
        final page = await client.listConversations(
          providerId: provider.id,
          projectFilter: scope.filter,
          limit: conversationPageSize,
        );
        if (!_ownsRuntime(generation, client)) return;
        acceptSnapshot(page.snapshotCursor);
        conversations = mergeRoutedConversations(
          conversations,
          page.conversations,
        );
        _conversationCursors[scope] = page.nextCursor;
        _loadedConversationScopes.add(scope);
      }
      window.install(
        baselineCursor: connectedHandshake.eventCursor,
        snapshotCursor: snapshotCursor,
        onEvent: (incoming) {
          if (_ownsRuntime(generation, client)) {
            final observed = incoming is ObservedGatewayEvent ? incoming : null;
            traceRecorder.runWithContext(
              observed?.traceContext,
              () => _applyEvent(observed?.event ?? incoming),
            );
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
      for (final provider in handshake?.providers ?? const <GatewayProvider>[]) {
        _ensureProviderLists(provider);
      }
      _retryableFailure = false;
      _reconnectAttempt = 0;
      logger.info(
        'Device ${device.deviceId} is online with ${providers.length} '
        'provider(s), ${projects.length} project(s), and '
        '${conversations.length} conversation(s); '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      _notifyListenersImmediately();
    } catch (value, stackTrace) {
      if (generation != _runtimeGeneration) return;
      final connectionError = value.toString();
      final window = _eventWindow;
      final client = _client;
      final failureGeneration = ++_runtimeGeneration;
      _eventWindow = null;
      _client = null;
    messageCache.clear();
      handshake = null;
      _resetConversationPagination();
      error = connectionError;
      _retryableFailure = isRetryableGatewayFailure(value);
      connectionState = DeviceConnectionState.failed;
      logger.warning(
        'Connection failed for device ${device.deviceId}; '
        'retryable=$_retryableFailure '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: value,
        stackTrace: stackTrace,
      );
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
    logger.info(
      'Reconnect scheduled for device ${device.deviceId} in '
      '${delay.inMilliseconds}ms (attempt $_reconnectAttempt)',
    );
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
    logger.info(
      'Discovery signal triggered immediate reconnect for device ${device.deviceId}',
    );
    _cancelReconnect();
    unawaited(_connect());
  }

  void _cancelReconnect({bool resetAttempt = false}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (resetAttempt) _reconnectAttempt = 0;
  }

  Future<void> loadMoreConversations({String? providerId}) async {
    final client = _client;
    final pendingRoutes = _conversationCursors.entries
        .where((entry) =>
            entry.value != null &&
            (providerId == null || entry.key.providerId == providerId) &&
            entry.key == _recentScopeForProvider(entry.key.providerId))
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
            providerId: entry.key.providerId,
            projectFilter: entry.key.filter,
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
      logger.fine(
        'Conversation page loaded for device ${device.deviceId} '
        'routes=${pendingRoutes.length} total=${conversations.length}',
      );
    } catch (value, stackTrace) {
      if (!_ownsRuntime(generation, client)) return;
      _loadMoreError = value.toString();
      logger.warning(
        'Conversation pagination failed for device ${device.deviceId} '
        'routes=${pendingRoutes.length}',
        error: value,
        stackTrace: stackTrace,
      );
    } finally {
      if (_ownsRuntime(generation, client)) {
        _isLoadingMoreConversations = false;
        _notifyListenersImmediately();
      }
    }
  }

  Future<void> loadMoreSelectedProviderConversations() =>
      loadMoreConversations(providerId: selectedProvider?.id);

  Future<void> ensureProjectConversations(GatewayProject project) async {
    final scope = _ConversationListScope.project(project.resource);
    if (_loadedConversationScopes.contains(scope) ||
        _loadingProjectConversationScopes.contains(scope)) {
      return;
    }
    await _loadProjectConversationPage(scope, cursor: null);
  }

  bool canLoadMoreProjectConversations(GatewayProject project) =>
      connectionState == DeviceConnectionState.online &&
      _conversationCursors[_ConversationListScope.project(project.resource)] !=
          null;

  Future<void> loadMoreProjectConversations(GatewayProject project) async {
    final scope = _ConversationListScope.project(project.resource);
    final cursor = _conversationCursors[scope];
    if (cursor == null) return;
    await _loadProjectConversationPage(scope, cursor: cursor);
  }

  Future<void> _loadProjectConversationPage(
    _ConversationListScope scope, {
    required String? cursor,
  }) async {
    final client = _client;
    if (connectionState != DeviceConnectionState.online ||
        client == null ||
        _loadingProjectConversationScopes.contains(scope)) {
      return;
    }
    final generation = _runtimeGeneration;
    _loadingProjectConversationScopes.add(scope);
    _loadMoreError = null;
    _notifyListenersImmediately();
    try {
      final page = await client.listConversations(
        providerId: scope.providerId,
        projectFilter: scope.filter,
        cursor: cursor,
        limit: conversationPageSize,
      );
      if (!_ownsRuntime(generation, client)) return;
      conversations = mergeRoutedConversations(
        conversations,
        page.conversations,
      );
      _conversationCursors[scope] = page.nextCursor;
      _loadedConversationScopes.add(scope);
      logger.fine(
        'Project conversation page loaded for device ${device.deviceId} '
        'provider=${scope.providerId} count=${page.conversations.length}',
      );
    } catch (value, stackTrace) {
      if (_ownsRuntime(generation, client)) {
        _loadMoreError = value.toString();
        logger.warning(
          'Project conversation pagination failed for device '
          '${device.deviceId} provider=${scope.providerId}',
          error: value,
          stackTrace: stackTrace,
        );
      }
    } finally {
      if (_ownsRuntime(generation, client)) {
        _loadingProjectConversationScopes.remove(scope);
        _notifyListenersImmediately();
      }
    }
  }

  Future<void> loadMoreSelectedProviderProjects() async {
    final provider = selectedProvider;
    final gatewayClient = _client;
    final cursor = provider == null ? null : _projectCursors[provider.id];
    if (connectionState != DeviceConnectionState.online ||
        provider == null ||
        cursor == null ||
        gatewayClient == null ||
        gatewayClient is! ProjectGatewayClient ||
        _isLoadingMoreProjects) {
      return;
    }
    final projectClient = gatewayClient as ProjectGatewayClient;
    final generation = _runtimeGeneration;
    _isLoadingMoreProjects = true;
    _loadMoreProjectsError = null;
    _notifyListenersImmediately();
    try {
      final page = await projectClient.listProjects(
        providerId: provider.id,
        cursor: cursor,
        limit: conversationPageSize,
      );
      if (!_ownsRuntime(generation, gatewayClient)) return;
      projects = mergeRoutedProjects(projects, page.projects);
      _projectCursors[provider.id] = page.nextCursor;
      logger.fine(
        'Project page loaded for device ${device.deviceId} '
        'provider=${provider.id} total=${projects.length}',
      );
    } catch (value, stackTrace) {
      if (_ownsRuntime(generation, gatewayClient)) {
        _loadMoreProjectsError = value.toString();
        logger.warning(
          'Project pagination failed for device ${device.deviceId} '
          'provider=${provider.id}',
          error: value,
          stackTrace: stackTrace,
        );
      }
    } finally {
      if (_ownsRuntime(generation, gatewayClient)) {
        _isLoadingMoreProjects = false;
        _notifyListenersImmediately();
      }
    }
  }

  Future<ConversationSummary> createConversation({
    required GatewayProvider provider,
    String? title,
    String? workspaceRoot,
    String? permissionLevel,
    String? model,
    String? reasoningEffort,
    String? workspaceMode,
    GatewayProject? project,
  }) async {
    final lease = runtimeLease;
    if (lease == null ||
        !provider.isAvailable ||
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
    final requestedWorkspaceRoot = workspaceRoot?.trim();
    // Project ownership and the execution directory are separate request fields.
    final effectiveWorkspaceRoot = requestedWorkspaceRoot?.isNotEmpty == true
        ? requestedWorkspaceRoot
        : project?.roots
            .map((root) => root.path.trim())
            .where((path) => path.isNotEmpty)
            .firstOrNull;
    logger.info(
      'Conversation create started for device ${device.deviceId} '
      'provider=${provider.id} projectAttached=${project != null}',
    );
    final stopwatch = Stopwatch()..start();
    try {
      final conversation = await lease._client.createConversation(
        providerId: provider.id,
        title: title?.trim().isEmpty == true ? null : title?.trim(),
        permissionLevel: effectivePermissionLevel,
        model: effectiveModel,
        reasoningEffort: effectiveReasoningEffort,
        workspaceRoot: effectiveWorkspaceRoot,
        workspaceMode: effectiveWorkspaceMode,
        project: project?.resource,
      );
      if (!ownsRuntimeLease(lease)) {
        throw StateError('连接已变化，请重新新建会话');
      }
      _upsertEventConversation(conversation);
      _notifyListenersImmediately();
      logger.info(
        'Conversation create succeeded for device ${device.deviceId} '
        'provider=${provider.id} conversation=${conversation.id} '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return conversation;
    } catch (error, stackTrace) {
      logger.warning(
        'Conversation create failed for device ${device.deviceId} '
        'provider=${provider.id} elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<GatewayProject> createProject({
    required GatewayProvider provider,
    required String name,
    required List<ProjectRoot> roots,
    Map<String, String> metadata = const {},
  }) async {
    final gatewayClient = _client;
    final trimmedName = name.trim();
    if (connectionState != DeviceConnectionState.online ||
        gatewayClient == null ||
        gatewayClient is! ProjectGatewayClient ||
        !provider.isAvailable ||
        !provider.methods.contains('project.create')) {
      throw StateError('当前 Provider 不支持新建项目');
    }
    if (trimmedName.isEmpty) throw ArgumentError.value(name, 'name', '不能为空');
    final projectClient = gatewayClient as ProjectGatewayClient;
    final generation = _runtimeGeneration;
    logger.info(
      'Project create started for device ${device.deviceId} '
      'provider=${provider.id} rootCount=${roots.length}',
    );
    try {
      final project = await projectClient.createProject(
        providerId: provider.id,
        idempotencyKey:
            'remote-project-${DateTime.now().microsecondsSinceEpoch}-${++_projectRequestSequence}',
        name: trimmedName,
        roots: _trimProjectRoots(roots),
        metadata: Map.unmodifiable(metadata),
      );
      if (!_ownsRuntime(generation, gatewayClient)) {
        throw StateError('连接已变化，请重新新建项目');
      }
      _upsertProject(project);
      _notifyListenersImmediately();
      logger.info(
        'Project create succeeded for device ${device.deviceId} '
        'provider=${provider.id} project=${project.resource.key}',
      );
      return project;
    } catch (error, stackTrace) {
      logger.warning(
        'Project create failed for device ${device.deviceId} '
        'provider=${provider.id}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<GatewayProject> updateProject({
    required GatewayProvider provider,
    required GatewayProject project,
    String? name,
    List<ProjectRoot>? roots,
    Map<String, String>? metadata,
  }) async {
    final gatewayClient = _client;
    if (connectionState != DeviceConnectionState.online ||
        gatewayClient == null ||
        gatewayClient is! ProjectGatewayClient ||
        !provider.isAvailable ||
        !provider.methods.contains('project.update')) {
      throw StateError('当前 Provider 不支持编辑项目');
    }
    if (project.resource.providerId != provider.id) {
      throw ArgumentError('项目不属于当前 Provider');
    }
    if (name == null && roots == null && metadata == null) {
      throw ArgumentError('至少需要更新一个项目字段');
    }
    final trimmedName = name?.trim();
    if (trimmedName != null && trimmedName.isEmpty) {
      throw ArgumentError.value(name, 'name', '不能为空');
    }
    final projectClient = gatewayClient as ProjectGatewayClient;
    final generation = _runtimeGeneration;
    logger.info(
      'Project update started for device ${device.deviceId} '
      'provider=${provider.id} project=${project.resource.key}',
    );
    try {
      final updated = await projectClient.updateProject(
        project: project.resource,
        name: trimmedName,
        roots: roots == null ? null : _trimProjectRoots(roots),
        metadata: metadata == null ? null : Map.unmodifiable(metadata),
      );
      if (!_ownsRuntime(generation, gatewayClient)) {
        throw StateError('连接已变化，请重新编辑项目');
      }
      _upsertProject(updated);
      _notifyListenersImmediately();
      logger.info(
        'Project update succeeded for device ${device.deviceId} '
        'provider=${provider.id} project=${project.resource.key}',
      );
      return updated;
    } catch (error, stackTrace) {
      logger.warning(
        'Project update failed for device ${device.deviceId} '
        'provider=${provider.id} project=${project.resource.key}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  Future<void> deleteProject({
    required GatewayProvider provider,
    required GatewayProject project,
  }) async {
    final gatewayClient = _client;
    if (connectionState != DeviceConnectionState.online ||
        gatewayClient == null ||
        gatewayClient is! ProjectGatewayClient ||
        !provider.isAvailable ||
        !provider.methods.contains('project.delete')) {
      throw StateError('当前 Provider 不支持删除项目');
    }
    if (project.resource.providerId != provider.id) {
      throw ArgumentError('项目不属于当前 Provider');
    }
    final projectClient = gatewayClient as ProjectGatewayClient;
    final generation = _runtimeGeneration;
    logger.info(
      'Project delete started for device ${device.deviceId} '
      'provider=${provider.id} project=${project.resource.key}',
    );
    try {
      await projectClient.deleteProject(project.resource);
      if (!_ownsRuntime(generation, gatewayClient)) {
        throw StateError('连接已变化，请重新删除项目');
      }
      _removeProject(project.resource);
      _notifyListenersImmediately();
      logger.info(
        'Project delete succeeded for device ${device.deviceId} '
        'provider=${provider.id} project=${project.resource.key}',
      );
    } catch (error, stackTrace) {
      logger.warning(
        'Project delete failed for device ${device.deviceId} '
        'provider=${provider.id} project=${project.resource.key}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  List<ProjectRoot> _trimProjectRoots(List<ProjectRoot> roots) => roots
      .map((root) => ProjectRoot(path: root.path.trim()))
      .where((root) => root.path.isNotEmpty)
      .toList(growable: false);

  void _upsertProject(GatewayProject incoming) {
    projects = mergeRoutedProjects(projects, [incoming]);
  }

  void _removeProject(RoutedResourceId resource) {
    projects = [
      for (final project in projects)
        if (project.resource != resource) project,
    ];
    _loadedConversationScopes.remove(
      _ConversationListScope.project(resource),
    );
    _conversationCursors.remove(_ConversationListScope.project(resource));
  }

  bool _ownsRuntime(int generation, GatewayClient client) =>
      generation == _runtimeGeneration && identical(_client, client);

  void _resetConversationPagination() {
    _initialConversationLoads.clear();
    conversations = const [];
    projects = const [];
    _conversationCursors.clear();
    _loadedConversationScopes.clear();
    _loadingProjectConversationScopes.clear();
    _projectCursors.clear();
    _projectRefreshes.clear();
    _pendingProjectRefreshes.clear();
    _conversationRefreshes.clear();
    _pendingConversationRefreshTurns.clear();
    _livePreviewByContent.clear();
    _isLoadingMoreConversations = false;
    _loadMoreError = null;
    _isLoadingMoreProjects = false;
    _loadMoreProjectsError = null;
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
    messageCache.clear();
    handshake = null;
    _resetConversationPagination();
    error = message;
    _retryableFailure = isRetryableGatewayFailure(cause);
    connectionState = DeviceConnectionState.failed;
    logger.warning(
      'Runtime event stream failed for device ${device.deviceId}; '
      'retryable=$_retryableFailure',
      error: cause,
    );
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

  void _applyProviderUpdate(GatewayProvider provider) {
      final currentHandshake = handshake;
      if (currentHandshake == null) return;
      final providers = [...currentHandshake.providers];
      final index = providers.indexWhere(
        (item) => item.id == provider.id,
      );
      if (index == -1) {
        providers.add(provider);
        handshake = currentHandshake.withProviders(providers);
        _ensureProviderLists(provider);
        final client = _client;
        if (client != null) unawaited(_refreshProviderDescription(providerId: provider.id, revision: provider.capabilities.revision, generation: _runtimeGeneration, client: client));
        _notifyListenersImmediately();
        return;
      }
      final previous = providers[index];
      if (previous.generation != null && provider.generation != null && provider.generation! < previous.generation!) return;
      final revisionChanged = previous.generation != provider.generation || previous.capabilities.revision !=
          provider.capabilities.revision;
      if (revisionChanged || previous.isAvailable != provider.isAvailable) {
        messageCache.invalidateProvider(provider.id);
      }
      providers[index] = !revisionChanged && previous.capabilitiesLoaded
          ? provider.withCapabilities(previous.capabilities)
          : provider;
      handshake = currentHandshake.withProviders(providers);
      _notifyListenersImmediately();
      _ensureProviderLists(providers[index]);
      if (revisionChanged || !providers[index].capabilitiesLoaded) {
        final client = _client;
        if (client != null) {
          unawaited(_refreshProviderDescription(
            providerId: provider.id,
            revision: provider.capabilities.revision,
            generation: _runtimeGeneration,
            client: client,
          ));
        }
      }
  }

  void _applyEvent(GatewayEvent event) {
    if (event is GatewayProviderChangedEvent) {
      _applyProviderUpdate(event.provider);
      return;
    }
    if (event is ProjectChangedEvent) {
      if (event.changeType == ProjectChangeType.deleted) {
        _removeProject(event.project);
        _notifyListenersImmediately();
      }
      _queueProjectRefresh(event.project.providerId);
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
    final providerId = _providerIdForTurn(event.turn);
    if (providerId != null) {
      unawaited(_refreshConversationsForEvent(providerId, event.turn));
    }
  }

  Future<void> _refreshProviderDescription({
    required String providerId,
    required String revision,
    required int generation,
    required GatewayClient client,
  }) async {
    try {
      final described = await client.describeProvider(providerId);
      if (!_ownsRuntime(generation, client) ||
          described.id != providerId ||
          described.capabilities.revision != revision) {
        return;
      }
      final currentHandshake = handshake;
      if (currentHandshake == null) return;
      final providers = [...currentHandshake.providers];
      final index = providers.indexWhere((provider) =>
          provider.id == providerId &&
          provider.capabilities.revision == revision);
      if (index == -1) return;
      if (providers[index].generation != described.generation) return;
      providers[index] = described;
      handshake = currentHandshake.withProviders(providers);
      _notifyListenersImmediately();
      _ensureProviderLists(described);
    } catch (error, stackTrace) {
      // The summary remains usable. A later provider.changed event or reconnect
      // retries the lazy description without discarding runtime information.
      _logBackgroundWarning(
        'provider:$providerId',
        'Provider capability refresh failed for device ${device.deviceId} '
        'provider=$providerId revision=$revision',
        error,
        stackTrace,
      );
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
        : current.mergeRuntimeMetadata(incoming).withReadState(current.readState);
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
            project: eventConversation.project,
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
      project: current.project,
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
      project: current.project,
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

  String? _providerIdForTurn(TurnTask turn) {
    return (turn.conversationResource ?? turn.resource)?.providerId;
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
    String providerId,
    TurnTask turn,
  ) async {
    final pending = _pendingConversationRefreshTurns.putIfAbsent(
      providerId,
      () => {},
    );
    final current = pending[turn.id];
    if (current == null || turn.updatedAt.isAfter(current.updatedAt)) {
      pending[turn.id] = turn;
    }
    if (!_conversationRefreshes.add(providerId)) return;
    var continuePending = true;
    try {
      while (true) {
        final client = _client;
        final generation = _runtimeGeneration;
        if (client == null) return;
        final batch = _pendingConversationRefreshTurns.remove(providerId);
        if (batch == null || batch.isEmpty) return;
        try {
          final loadedScopes = _loadedConversationScopes
              .where((scope) => scope.providerId == providerId)
              .toList(growable: false);
          final scopes = loadedScopes.isEmpty
              ? [_recentScopeForProvider(providerId)]
              : loadedScopes;
          for (final scope in scopes) {
            final page = await client.listConversations(
              providerId: providerId,
              projectFilter: scope.filter,
              limit: conversationPageSize,
            );
            if (!_ownsRuntime(generation, client)) return;
            conversations = mergeRoutedConversations(
              conversations,
              page.conversations,
            );
            _conversationCursors[scope] = page.nextCursor;
            _loadedConversationScopes.add(scope);
          }
          for (final pendingTurn in batch.values) {
            _applyTurnToConversation(pendingTurn);
          }
          _notifyListenersImmediately();
        } catch (error, stackTrace) {
          continuePending = false;
          final retry = _pendingConversationRefreshTurns.putIfAbsent(
            providerId,
            () => {},
          );
          for (final pendingTurn in batch.values) {
            retry.putIfAbsent(pendingTurn.id, () => pendingTurn);
          }
          _logBackgroundWarning(
            'conversation:$providerId',
            'Event-driven conversation refresh failed for device '
            '${device.deviceId} provider=$providerId '
            'pendingTurns=${batch.length}',
            error,
            stackTrace,
          );
          return;
        }
      }
    } finally {
      _conversationRefreshes.remove(providerId);
      if (continuePending &&
          connectionState == DeviceConnectionState.online &&
          _client != null &&
          _pendingConversationRefreshTurns[providerId]?.isNotEmpty == true) {
        final next = _pendingConversationRefreshTurns[providerId]!.values.first;
        unawaited(_refreshConversationsForEvent(providerId, next));
      }
    }
  }

  final Set<_ConversationListScope> _initialConversationLoads = {};

  void _ensureProviderLists(GatewayProvider provider) {
    if (connectionState != DeviceConnectionState.online || !provider.isAvailable) return;
    if (provider.methods.contains('project.list') && !_projectCursors.containsKey(provider.id)) {
      if (!_projectRefreshes.contains(provider.id)) _queueProjectRefresh(provider.id);
    }
    final scope = _recentScope(provider);
    if (provider.methods.contains('conversation.list') && !_loadedConversationScopes.contains(scope)) {
      unawaited(_loadInitialProviderConversations(provider, scope));
    }
  }

  Future<void> _loadInitialProviderConversations(GatewayProvider provider, _ConversationListScope scope) async {
    final client = _client;
    final generation = _runtimeGeneration;
    if (client == null || !_initialConversationLoads.add(scope)) return;
    try {
      final page = await client.listConversations(providerId: provider.id,
        projectFilter: scope.filter, limit: conversationPageSize);
      if (!_ownsRuntime(generation, client) || _providerForId(provider.id)?.generation != provider.generation) return;
      conversations = mergeRoutedConversations(conversations, page.conversations);
      _conversationCursors[scope] = page.nextCursor;
      _loadedConversationScopes.add(scope);
      _notifyListenersImmediately();
    } catch (error, stackTrace) {
      _logBackgroundWarning('provider:${provider.id}', 'Provider conversation loading failed', error, stackTrace);
    } finally {
      if (generation == _runtimeGeneration) _initialConversationLoads.remove(scope);
    }
  }

  void _queueProjectRefresh(String providerId) {
    _pendingProjectRefreshes.add(providerId);
    unawaited(_refreshProjectsForEvent(providerId));
  }

  Future<void> _refreshProjectsForEvent(String providerId) async {
    if (!_projectRefreshes.add(providerId)) return;
    var continuePending = true;
    try {
      while (_pendingProjectRefreshes.remove(providerId)) {
        final gatewayClient = _client;
        final generation = _runtimeGeneration;
        if (gatewayClient == null ||
            gatewayClient is! ProjectGatewayClient ||
            connectionState != DeviceConnectionState.online) {
          return;
        }
        final projectClient = gatewayClient as ProjectGatewayClient;
        final provider = _providerForId(providerId);
        if (provider?.methods.contains('project.list') != true) return;
        try {
          final page = await projectClient.listProjects(
            providerId: providerId,
            limit: conversationPageSize,
          );
          if (!_ownsRuntime(generation, gatewayClient)) return;
          projects = replaceProviderProjects(projects, providerId, page.projects);
          _projectCursors[providerId] = page.nextCursor;
          _notifyListenersImmediately();
        } catch (error, stackTrace) {
          continuePending = false;
          _pendingProjectRefreshes.add(providerId);
          _logBackgroundWarning(
            'project:$providerId',
            'Event-driven project refresh failed for device '
            '${device.deviceId} provider=$providerId',
            error,
            stackTrace,
          );
          return;
        }
      }
    } finally {
      _projectRefreshes.remove(providerId);
      if (continuePending && _pendingProjectRefreshes.contains(providerId)) {
        unawaited(_refreshProjectsForEvent(providerId));
      }
    }
  }

  Future<void> disconnect() async {
    logger.info('Disconnect requested for device ${device.deviceId}');
    _reconnectEnabled = false;
    _retryableFailure = false;
    _cancelReconnect(resetAttempt: true);
    final window = _eventWindow;
    final client = _client;
    _runtimeGeneration++;
    _eventWindow = null;
    _client = null;
    messageCache.clear();
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
    logger.info('Device ${device.deviceId} is offline');
  }

  void _logBackgroundWarning(
    String key,
    String message,
    Object error,
    StackTrace stackTrace,
  ) {
    final now = DateTime.now();
    final previous = _backgroundWarningTimes[key];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 1)) {
      _suppressedBackgroundWarnings[key] =
          (_suppressedBackgroundWarnings[key] ?? 0) + 1;
      return;
    }
    final suppressed = _suppressedBackgroundWarnings.remove(key) ?? 0;
    _backgroundWarningTimes[key] = now;
    logger.warning(
      suppressed == 0 ? message : '$message; suppressed=$suppressed',
      error: error,
      stackTrace: stackTrace,
    );
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
    messageCache.clear();
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

List<GatewayProject> sortProjects(Iterable<GatewayProject> values) {
  return values.toList(growable: false)
    ..sort((left, right) {
      final position = left.position.compareTo(right.position);
      return position != 0 ? position : left.key.compareTo(right.key);
    });
}

List<GatewayProject> mergeRoutedProjects(
  Iterable<GatewayProject> existing,
  Iterable<GatewayProject> incoming,
) {
  final projects = <String, GatewayProject>{
    for (final project in existing) project.key: project,
  };
  for (final project in incoming) {
    final current = projects[project.key];
    if (current == null || !project.updatedAt.isBefore(current.updatedAt)) {
      projects[project.key] = project;
    }
  }
  return sortProjects(projects.values);
}

List<GatewayProject> replaceProviderProjects(
  Iterable<GatewayProject> existing,
  String providerId,
  Iterable<GatewayProject> replacement,
) => sortProjects([
      for (final project in existing)
        if (project.resource.providerId != providerId) project,
      ...replacement,
    ]);

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

enum _ConversationListScopeKind { all, standalone, project }

class _ConversationListScope {
  const _ConversationListScope._({
    required this.providerId,
    required this.kind,
    this.project,
  });

  const _ConversationListScope.all(String providerId)
      : this._(providerId: providerId, kind: _ConversationListScopeKind.all);

  const _ConversationListScope.standalone(String providerId)
      : this._(
          providerId: providerId,
          kind: _ConversationListScopeKind.standalone,
        );

  _ConversationListScope.project(RoutedResourceId project)
      : this._(
          providerId: project.providerId,
          kind: _ConversationListScopeKind.project,
          project: project,
        );

  final String providerId;
  final _ConversationListScopeKind kind;
  final RoutedResourceId? project;

  ConversationProjectFilter get filter => switch (kind) {
        _ConversationListScopeKind.all => const AllConversationFilter(),
        _ConversationListScopeKind.standalone =>
          const StandaloneConversationFilter(),
        _ConversationListScopeKind.project => ProjectConversationFilter(project!),
      };

  @override
  bool operator ==(Object other) =>
      other is _ConversationListScope &&
      other.providerId == providerId &&
      other.kind == kind &&
      other.project == project;

  @override
  int get hashCode => Object.hash(providerId, kind, project);
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
