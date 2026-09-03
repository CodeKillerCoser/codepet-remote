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
  }) : assert(reconnectDelays.isNotEmpty);

  static const int conversationPageSize = 20;

  PairedDevice device;
  final GatewayClient Function() clientFactory;
  final bool autoReconnect;
  final List<Duration> reconnectDelays;
  GatewayClient? _client;
  GatewayEventWindow? _eventWindow;
  Timer? _reconnectTimer;
  final Map<_ConversationListScope, String?> _conversationCursors = {};
  final Set<_ConversationListScope> _loadedConversationScopes = {};
  final Map<GatewayProviderRoute, String?> _projectCursors = {};
  final Set<GatewayProviderRoute> _projectRefreshes = {};
  final Set<GatewayProviderRoute> _pendingProjectRefreshes = {};
  final Set<GatewayProviderRoute> _conversationRefreshes = {};
  final Map<GatewayProviderRoute, Map<String, TurnTask>>
      _pendingConversationRefreshTurns = {};
  final Map<String, String> _livePreviewByContent = {};
  bool _isLoadingMoreConversations = false;
  String? _loadMoreError;
  bool _isLoadingMoreProjects = false;
  String? _loadMoreProjectsError;
  int _projectRequestSequence = 0;
  int _runtimeGeneration = 0;
  int _reconnectAttempt = 0;
  bool _reconnectEnabled = false;
  bool _disposed = false;
  Timer? _conversationNotificationTimer;
  GatewayProviderRoute? _selectedProviderRoute;
  DeviceConnectionState connectionState = DeviceConnectionState.offline;
  GatewayHandshake? handshake;
  String? error;
  List<ConversationSummary> conversations = const [];
  List<GatewayProject> projects = const [];

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
  bool get selectedProviderSupportsProjects =>
      selectedProvider?.methods.contains('project.list') == true;
  List<GatewayProject> get selectedProviderProjects {
    final route = selectedProvider?.route;
    if (route == null) return const [];
    return projects
        .where((project) => project.resource.route == route)
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
        _projectCursors[provider.route] != null;
  }
  bool get isLoadingMoreProjects => _isLoadingMoreProjects;
  String? get loadMoreProjectsError => _loadMoreProjectsError;

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
  GatewayProvider? _providerForRoute(GatewayProviderRoute route) {
    for (final provider in handshake?.providers ?? const <GatewayProvider>[]) {
      if (provider.route == route) return provider;
    }
    return null;
  }
  _ConversationListScope _recentScope(GatewayProvider provider) =>
      provider.methods.contains('project.list')
          ? _ConversationListScope.standalone(provider.route)
          : _ConversationListScope.all(provider.route);
  _ConversationListScope _recentScopeForRoute(GatewayProviderRoute route) {
    final provider = _providerForRoute(route);
    return provider == null
        ? _ConversationListScope.all(route)
        : _recentScope(provider);
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
      var hasSnapshot = false;
      void acceptSnapshot(String cursor) {
        if (hasSnapshot) return;
        snapshotCursor = cursor;
        hasSnapshot = true;
      }
      final projectClient = client is ProjectGatewayClient
          ? client as ProjectGatewayClient
          : null;
      for (final provider in projectListProviders) {
        if (projectClient == null) {
          throw UnsupportedError(
            'Gateway SDK adapter does not implement advertised project methods',
          );
        }
        final page = await projectClient.listProjects(
          route: provider.route,
          limit: conversationPageSize,
        );
        if (!_ownsRuntime(generation, client)) return;
        acceptSnapshot(page.snapshotCursor);
        projects = mergeRoutedProjects(projects, page.projects);
        _projectCursors[provider.route] = page.nextCursor;
      }
      for (final provider in conversationListProviders) {
        final scope = _recentScope(provider);
        final page = await client.listConversations(
          route: provider.route,
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
      connectionState = DeviceConnectionState.failed;
      _notifyListenersImmediately();
      try {
        await window?.close();
      } catch (_) {}
      try {
        await client?.close();
      } catch (_) {}
      if (isRetryableGatewayFailure(value)) {
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
      !_disposed;

  void _cancelReconnect({bool resetAttempt = false}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (resetAttempt) _reconnectAttempt = 0;
  }

  Future<void> loadMoreConversations({GatewayProviderRoute? route}) async {
    final client = _client;
    final pendingRoutes = _conversationCursors.entries
        .where((entry) =>
            entry.value != null &&
            (route == null || entry.key.route == route) &&
            entry.key == _recentScopeForRoute(entry.key.route))
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
            route: entry.key.route,
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

  Future<void> ensureProjectConversations(GatewayProject project) async {
    final scope = _ConversationListScope.project(project.resource);
    if (_loadedConversationScopes.contains(scope)) return;
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
        _isLoadingMoreConversations) {
      return;
    }
    final generation = _runtimeGeneration;
    _isLoadingMoreConversations = true;
    _loadMoreError = null;
    _notifyListenersImmediately();
    try {
      final page = await client.listConversations(
        route: scope.route,
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
    } catch (value) {
      if (_ownsRuntime(generation, client)) _loadMoreError = value.toString();
    } finally {
      if (_ownsRuntime(generation, client)) {
        _isLoadingMoreConversations = false;
        _notifyListenersImmediately();
      }
    }
  }

  Future<void> loadMoreSelectedProviderProjects() async {
    final provider = selectedProvider;
    final gatewayClient = _client;
    final cursor = provider == null ? null : _projectCursors[provider.route];
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
        route: provider.route,
        cursor: cursor,
        limit: conversationPageSize,
      );
      if (!_ownsRuntime(generation, gatewayClient)) return;
      projects = mergeRoutedProjects(projects, page.projects);
      _projectCursors[provider.route] = page.nextCursor;
    } catch (value) {
      if (_ownsRuntime(generation, gatewayClient)) {
        _loadMoreProjectsError = value.toString();
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
      project: project?.resource,
    );
    if (!ownsRuntimeLease(lease)) {
      throw StateError('连接已变化，请重新新建会话');
    }
    _upsertEventConversation(conversation);
    _notifyListenersImmediately();
    return conversation;
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
        provider.status != ProviderStatus.ready ||
        !provider.methods.contains('project.create')) {
      throw StateError('当前 Provider 不支持新建项目');
    }
    if (trimmedName.isEmpty) throw ArgumentError.value(name, 'name', '不能为空');
    final projectClient = gatewayClient as ProjectGatewayClient;
    final generation = _runtimeGeneration;
    final project = await projectClient.createProject(
      route: provider.route,
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
    return project;
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
        provider.status != ProviderStatus.ready ||
        !provider.methods.contains('project.update')) {
      throw StateError('当前 Provider 不支持编辑项目');
    }
    if (project.resource.route != provider.route) {
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
    return updated;
  }

  Future<void> deleteProject({
    required GatewayProvider provider,
    required GatewayProject project,
  }) async {
    final gatewayClient = _client;
    if (connectionState != DeviceConnectionState.online ||
        gatewayClient == null ||
        gatewayClient is! ProjectGatewayClient ||
        provider.status != ProviderStatus.ready ||
        !provider.methods.contains('project.delete')) {
      throw StateError('当前 Provider 不支持删除项目');
    }
    if (project.resource.route != provider.route) {
      throw ArgumentError('项目不属于当前 Provider');
    }
    final projectClient = gatewayClient as ProjectGatewayClient;
    final generation = _runtimeGeneration;
    await projectClient.deleteProject(project.resource);
    if (!_ownsRuntime(generation, gatewayClient)) {
      throw StateError('连接已变化，请重新删除项目');
    }
    _removeProject(project.resource);
    _notifyListenersImmediately();
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
    conversations = const [];
    projects = const [];
    _conversationCursors.clear();
    _loadedConversationScopes.clear();
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
    handshake = null;
    _resetConversationPagination();
    error = message;
    connectionState = DeviceConnectionState.failed;
    _notifyListenersImmediately();
    try {
      await window?.close();
    } catch (_) {}
    try {
      await client.close();
    } catch (_) {}
    if (isRetryableGatewayFailure(cause)) {
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
    if (event is ProjectChangedEvent) {
      if (event.changeType == ProjectChangeType.deleted) {
        _removeProject(event.project);
        _notifyListenersImmediately();
      }
      _queueProjectRefresh(event.project.route);
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
          final loadedScopes = _loadedConversationScopes
              .where((scope) => scope.route == route)
              .toList(growable: false);
          final scopes = loadedScopes.isEmpty
              ? [_recentScopeForRoute(route)]
              : loadedScopes;
          for (final scope in scopes) {
            final page = await client.listConversations(
              route: route,
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

  void _queueProjectRefresh(GatewayProviderRoute route) {
    _pendingProjectRefreshes.add(route);
    unawaited(_refreshProjectsForEvent(route));
  }

  Future<void> _refreshProjectsForEvent(GatewayProviderRoute route) async {
    if (!_projectRefreshes.add(route)) return;
    var continuePending = true;
    try {
      while (_pendingProjectRefreshes.remove(route)) {
        final gatewayClient = _client;
        final generation = _runtimeGeneration;
        if (gatewayClient == null ||
            gatewayClient is! ProjectGatewayClient ||
            connectionState != DeviceConnectionState.online) {
          return;
        }
        final projectClient = gatewayClient as ProjectGatewayClient;
        final provider = _providerForRoute(route);
        if (provider?.methods.contains('project.list') != true) return;
        try {
          final page = await projectClient.listProjects(
            route: route,
            limit: conversationPageSize,
          );
          if (!_ownsRuntime(generation, gatewayClient)) return;
          projects = replaceProviderProjects(projects, route, page.projects);
          _projectCursors[route] = page.nextCursor;
          _notifyListenersImmediately();
        } catch (_) {
          continuePending = false;
          _pendingProjectRefreshes.add(route);
          return;
        }
      }
    } finally {
      _projectRefreshes.remove(route);
      if (continuePending && _pendingProjectRefreshes.contains(route)) {
        unawaited(_refreshProjectsForEvent(route));
      }
    }
  }

  Future<void> disconnect() async {
    _reconnectEnabled = false;
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
    _cancelReconnect(resetAttempt: true);
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
  GatewayProviderRoute route,
  Iterable<GatewayProject> replacement,
) => sortProjects([
      for (final project in existing)
        if (project.resource.route != route) project,
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
    required this.route,
    required this.kind,
    this.project,
  });

  const _ConversationListScope.all(GatewayProviderRoute route)
      : this._(route: route, kind: _ConversationListScopeKind.all);

  const _ConversationListScope.standalone(GatewayProviderRoute route)
      : this._(route: route, kind: _ConversationListScopeKind.standalone);

  _ConversationListScope.project(RoutedResourceId project)
      : this._(
          route: project.route,
          kind: _ConversationListScopeKind.project,
          project: project,
        );

  final GatewayProviderRoute route;
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
      other.route == route &&
      other.kind == kind &&
      other.project == project;

  @override
  int get hashCode => Object.hash(route, kind, project);
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
