part of 'device_session.dart';

extension _DeviceSessionPagination on DeviceSession {
  void _applyConversationPage(
    _ConversationListScope scope,
    ConversationPage page, {
    required bool append,
  }) {
    conversations = mergeRoutedConversations(conversations, page.conversations);
    if (scope.project case final project?) {
      final keys = append
          ? _projectConversationKeys.putIfAbsent(project, () => {})
          : _projectConversationKeys[project] = {};
      keys.addAll(page.conversations.map(conversationRoutingKey));
    }
    _conversationCursors[scope] = page.nextCursor;
    _loadedConversationScopes.add(scope);
  }

  Future<void> _loadConversationPages({String? providerId}) async {
    final routes = _conversationCursors.entries
        .where(
          (entry) =>
              entry.value != null &&
              (providerId == null || entry.key.providerId == providerId) &&
              entry.key == _standaloneScopeForProvider(entry.key.providerId),
        )
        .toList();
    // Each page owns its error and in-flight gate; a slow/failing sibling cannot
    // withhold a successful page or stop paging after a Provider tab switch.
    await Future.wait([
      for (final entry in routes) _loadConversationPage(entry.key, entry.value),
    ]);
  }

  Future<void> _loadConversationPage(
    _ConversationListScope scope,
    String? cursor,
  ) async {
    final client = _client;
    final id = scope.providerId;
    final generation = _runtimeGeneration;
    final epoch = _providerEpoch(id);
    if (connectionState != DeviceConnectionState.online ||
        client == null ||
        _providerForId(id)?.isAvailable != true ||
        _conversationPageLoads.containsKey(scope)) {
      return;
    }
    final token = Object();
    _conversationPageLoads[scope] = token;
    _conversationErrors.remove(id);
    final window = client.openEventWindow();
    _notifyListenersImmediately();
    try {
      Future<ConversationPage> readPage(String? nextCursor) => client
          .listConversations(
            providerId: id,
            projectFilter: scope.filter,
            cursor: nextCursor,
            limit: DeviceSession.conversationPageSize,
          )
          .timeout(providerLoadTimeout);
      var append = cursor != null;
      ConversationPage page;
      try {
        page = await readPage(cursor);
      } on GatewayProtocolException catch (error) {
        if (scope.project == null || !append || error.code != 'invalid_cursor' ||
            !_ownsProviderLoad(generation, client, id, epoch)) {
          rethrow;
        }
        append = false;
        page = await readPage(null);
      }
      if (!_ownsProviderLoad(generation, client, id, epoch)) return;
      if (scope.project != null && cursor != null &&
          _conversationCursors[scope] != cursor) {
        return;
      }
      final tail = _snapshotTail(window, page.snapshotCursor);
      _applyConversationPage(scope, page, append: append);
      _replayConversationTail(tail, id);
      _conversationErrors.remove(id);
    } catch (error, stack) {
      if (!_ownsProviderLoad(generation, client, id, epoch)) return;
      _conversationErrors[id] = error.toString();
      _logBackgroundWarning(
        'conversation-page:$id',
        'Conversation page failed provider=$id',
        error,
        stack,
      );
    } finally {
      unawaited(_closeProviderWindow(window));
      if (identical(_conversationPageLoads[scope], token)) {
        _conversationPageLoads.remove(scope);
        _notifyListenersImmediately();
      }
    }
  }

  Future<void> _loadProjectPage() async {
    final client = _client;
    final provider = selectedProvider;
    if (client == null ||
        provider == null ||
        client is! ProjectGatewayClient ||
        connectionState != DeviceConnectionState.online ||
        _projectPageLoads.containsKey(provider.id)) {
      return;
    }
    final id = provider.id;
    final cursor = _projectCursors[id];
    if (cursor == null) return;
    final generation = _runtimeGeneration;
    final epoch = _providerEpoch(id);
    final token = Object();
    _projectPageLoads[id] = token;
    _projectErrors.remove(id);
    final window = client.openEventWindow();
    _notifyListenersImmediately();
    try {
      final page = await (client as ProjectGatewayClient)
          .listProjects(
            providerId: id,
            cursor: cursor,
            limit: DeviceSession.conversationPageSize,
          )
          .timeout(providerLoadTimeout);
      if (!_ownsProviderLoad(generation, client, id, epoch)) return;
      final tail = _snapshotTail(window, page.snapshotCursor);
      projects = mergeRoutedProjects(projects, page.projects);
      _projectCursors[id] = page.nextCursor;
      for (final event in tail.whereType<ProjectChangedEvent>()) {
        if (event.project.providerId == id &&
            event.changeType == ProjectChangeType.deleted) {
          _removeProject(event.project);
        }
      }
      _projectErrors.remove(id);
    } catch (error, stack) {
      if (!_ownsProviderLoad(generation, client, id, epoch)) return;
      _projectErrors[id] = error.toString();
      _logBackgroundWarning(
        'project-page:$id',
        'Project page failed provider=$id',
        error,
        stack,
      );
    } finally {
      unawaited(_closeProviderWindow(window));
      if (identical(_projectPageLoads[id], token)) {
        _projectPageLoads.remove(id);
        _notifyListenersImmediately();
      }
    }
  }
}
