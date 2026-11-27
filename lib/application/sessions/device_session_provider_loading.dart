part of 'device_session.dart';

extension _DeviceSessionProviderLoading on DeviceSession {
  int _providerEpoch(String id) => _providerEpochs[id] ?? 0;

  bool _ownsProviderLoad(
    int generation,
    GatewayClient client,
    String id,
    int epoch,
  ) =>
      _ownsRuntime(generation, client) &&
      _providerForId(id)?.isAvailable == true &&
      _providerEpoch(id) == epoch;

  void _setProviderData(
    String id,
    ProviderDataKind kind,
    ProviderDataStatus status, [
    Object? error,
  ]) {
    _providerData[(id, kind)] = ProviderDataState(
      status: status,
      error: error?.toString(),
    );
    _notifyListenersImmediately();
  }

  void _invalidateProviderLoads(String id) {
    _providerEpochs[id] = _providerEpoch(id) + 1;
    _providerData.removeWhere((key, _) => key.$1 == id);
    _projectRefreshes.remove(id);
    _initialConversationLoads.removeWhere((scope, _) => scope.providerId == id);
    _loadedConversationScopes.removeWhere((scope) => scope.providerId == id);
    _conversationCursors.removeWhere((scope, _) => scope.providerId == id);
    _projectCursors.remove(id);
    _conversationPageLoads.removeWhere((scope, _) => scope.providerId == id);
    _projectPageLoads.remove(id);
    _conversationErrors.remove(id);
    _projectErrors.remove(id);
    _conversationRefreshes.remove(id);
  }

  Future<void> _retryProviderData(String id, ProviderDataKind kind) async {
    final provider = _providerForId(id);
    final client = _client;
    if (client == null ||
        connectionState != DeviceConnectionState.online ||
        provider?.isAvailable != true) {
      return;
    }
    switch (kind) {
      case ProviderDataKind.capabilities:
        await _refreshProviderDescription(
          providerId: id,
          revision: provider!.capabilities.revision,
          generation: _runtimeGeneration,
          client: client,
        );
      case ProviderDataKind.projects:
        _pendingProjectRefreshes.add(id);
        await _refreshProjectsForEvent(id);
      case ProviderDataKind.conversations:
        await _loadInitialProviderConversations(
          provider!,
          _standaloneScope(provider),
        );
    }
  }

  Future<void> _closeProviderWindow(GatewayEventWindow window) async {
    try {
      await window.close();
    } catch (error, stack) {
      _logBackgroundWarning(
        'business-window',
        'Business event window cleanup failed',
        error,
        stack,
      );
    }
  }

  List<GatewayEvent> _snapshotTail(GatewayEventWindow window, String cursor) {
    final tail = <GatewayEvent>[];
    window.install(
      baselineCursor: window.startCursor ?? handshake!.eventCursor,
      snapshotCursor: cursor,
      onEvent: (event) =>
          tail.add(event is ObservedGatewayEvent ? event.event : event),
    );
    return tail;
  }

  void _replayConversationTail(List<GatewayEvent> tail, String providerId) {
    for (final event in tail) {
      if (event is ConversationUpsertedEvent &&
          event.conversation.providerId == providerId) {
        _upsertEventConversation(event.conversation);
      } else if (event is TurnUpsertedEvent &&
          _providerIdForTurn(event.turn) == providerId) {
        _applyTurnToConversation(event.turn);
      } else if (event is TurnOutputDeltaEvent &&
          event.providerId == providerId) {
        _applyDeltaToConversation(event);
      } else if (event is ConversationActivityChangedEvent) {
        for (final row
            in conversations
                .where(
                  (row) =>
                      row.providerId == providerId &&
                      (conversationRoutingKey(row) == event.conversationId ||
                          row.id == event.conversationId),
                )
                .toList()) {
          _setConversationReadState(
            row,
            ConversationReadState(
              unread: true,
              activityVersion: event.activityVersion,
            ),
          );
        }
      }
    }
  }

  void _removeProvider(String providerId) {
    final current = handshake;
    if (current == null || !current.providers.any((p) => p.id == providerId)) {
      return;
    }
    final remaining = current.providers
        .where((p) => p.id != providerId)
        .toList();
    handshake = current.withProviders(remaining);
    messageCache.invalidateProvider(providerId);
    _recentControllers.remove(providerId)?.dispose();
    _pausedInteractionProviders.remove(providerId);
    _releasingInteractionProviders.remove(providerId);
    _conversationCursors.removeWhere(
      (scope, _) => scope.providerId == providerId,
    );
    _loadedConversationScopes.removeWhere(
      (scope) => scope.providerId == providerId,
    );
    _invalidateProviderLoads(providerId);
    _projectCursors.remove(providerId);
    if (_selectedProviderId == providerId) {
      _selectedProviderId = remaining.isEmpty ? null : remaining.first.id;
    }
    _ensureSelectedProviderLists();
    _notifyListenersImmediately();
  }

  void _applyProviderUpdate(GatewayProvider provider) {
    final currentHandshake = handshake;
    if (currentHandshake == null) return;
    final providers = [...currentHandshake.providers];
    final index = providers.indexWhere((item) => item.id == provider.id);
    if (index == -1) {
      providers.add(provider);
      handshake = currentHandshake.withProviders(providers);
      _ensureProviderLists(provider);
      final client = _client;
      if (client != null &&
          provider.isAvailable &&
          !provider.capabilitiesLoaded) {
        unawaited(
          _refreshProviderDescription(
            providerId: provider.id,
            revision: provider.capabilities.revision,
            generation: _runtimeGeneration,
            client: client,
          ),
        );
      }
      _notifyListenersImmediately();
      return;
    }
    final previous = providers[index];
    if (previous.generation != null &&
        provider.generation != null &&
        provider.generation! < previous.generation!) {
      return;
    }
    final revisionChanged =
        previous.generation != provider.generation ||
        previous.capabilities.revision != provider.capabilities.revision;
    if (revisionChanged || previous.isAvailable != provider.isAvailable) {
      messageCache.invalidateProvider(provider.id);
      _invalidateProviderLoads(provider.id);
    }
    // Starting snapshots are provisional even when their revision matches Ready.
    providers[index] =
        !revisionChanged &&
            previous.status == ProviderStatus.ready &&
            provider.status == ProviderStatus.ready &&
            previous.capabilitiesLoaded
        ? provider.withCapabilities(previous.capabilities)
        : provider;
    handshake = currentHandshake.withProviders(providers);
    if (provider.isAvailable && provider.capabilitiesLoaded) {
      _providerData[(provider.id, ProviderDataKind.capabilities)] =
          const ProviderDataState(status: ProviderDataStatus.ready);
    }
    _notifyListenersImmediately();
    _ensureProviderLists(providers[index]);
    if (providers[index].isAvailable && !providers[index].capabilitiesLoaded) {
      final client = _client;
      if (client != null) {
        unawaited(
          _refreshProviderDescription(
            providerId: provider.id,
            revision: provider.capabilities.revision,
            generation: _runtimeGeneration,
            client: client,
          ),
        );
      }
    }
  }

  Future<void> _refreshProviderDescription({
    required String providerId,
    required String revision,
    required int generation,
    required GatewayClient client,
  }) async {
    final epoch = _providerEpoch(providerId);
    final key = (generation, providerId, epoch, revision);
    if (!_providerDescriptionLoads.add(key)) return;
    _setProviderData(
      providerId,
      ProviderDataKind.capabilities,
      ProviderDataStatus.loading,
    );
    try {
      final described = await client
          .describeProvider(providerId)
          .timeout(providerLoadTimeout);
      if (!_ownsProviderLoad(generation, client, providerId, epoch)) return;
      if (described.id != providerId ||
          described.capabilities.revision != revision) {
        throw const FormatException(
          'Provider description has stale identity or capabilities',
        );
      }
      final currentHandshake = handshake;
      if (currentHandshake == null) return;
      final providers = [...currentHandshake.providers];
      final index = providers.indexWhere(
        (provider) =>
            provider.id == providerId &&
            provider.capabilities.revision == revision,
      );
      if (index == -1) return;
      if (!providers[index].isAvailable ||
          !described.isAvailable ||
          providers[index].generation != described.generation) {
        return;
      }
      providers[index] = described;
      handshake = currentHandshake.withProviders(providers);
      _setProviderData(
        providerId,
        ProviderDataKind.capabilities,
        ProviderDataStatus.ready,
      );
      _ensureProviderLists(described);
    } catch (error, stackTrace) {
      if (!_ownsProviderLoad(generation, client, providerId, epoch)) return;
      _setProviderData(
        providerId,
        ProviderDataKind.capabilities,
        ProviderDataStatus.failed,
        error,
      );
      // The summary remains usable. A later provider.changed event or reconnect
      // retries the lazy description without discarding runtime information.
      _logBackgroundWarning(
        'provider:$providerId',
        'Provider capability refresh failed for device ${device.deviceId} '
            'provider=$providerId revision=$revision',
        error,
        stackTrace,
      );
    } finally {
      _providerDescriptionLoads.remove(key);
    }
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
    if (providerId != selectedProviderId) return;
    if (_conversationRefreshes.containsKey(providerId)) return;
    final refreshToken = Object();
    _conversationRefreshes[providerId] = refreshToken;
    final epoch = _providerEpoch(providerId);
    var continuePending = true;
    try {
      while (true) {
        if (providerId != selectedProviderId) return;
        final client = _client;
        final generation = _runtimeGeneration;
        if (client == null ||
            !_ownsProviderLoad(generation, client, providerId, epoch)) {
          return;
        }
        final batch = _pendingConversationRefreshTurns.remove(providerId);
        if (batch == null || batch.isEmpty) return;
        try {
          final loadedScopes = _loadedConversationScopes
              .where((scope) => scope.providerId == providerId)
              .toList(growable: false);
          final scopes = loadedScopes.isEmpty
              ? [_standaloneScopeForProvider(providerId)]
              : loadedScopes;
          for (final scope in scopes) {
            if (providerId != selectedProviderId) {
              final deferred = _pendingConversationRefreshTurns.putIfAbsent(
                providerId,
                () => {},
              );
              for (final turn in batch.values) {
                deferred.putIfAbsent(turn.id, () => turn);
              }
              return;
            }
            final page = await client
                .listConversations(
                  providerId: providerId,
                  projectFilter: scope.filter,
                  limit: DeviceSession.conversationPageSize,
                )
                .timeout(providerLoadTimeout);
            if (!_ownsProviderLoad(generation, client, providerId, epoch)) {
              return;
            }
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
          _setProviderData(
            providerId,
            ProviderDataKind.conversations,
            ProviderDataStatus.ready,
          );
        } catch (error, stackTrace) {
          continuePending = false;
          if (!_ownsProviderLoad(generation, client, providerId, epoch)) return;
          _setProviderData(
            providerId,
            ProviderDataKind.conversations,
            ProviderDataStatus.failed,
            error,
          );
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
      if (identical(_conversationRefreshes[providerId], refreshToken)) {
        _conversationRefreshes.remove(providerId);
        if (continuePending &&
            providerId == selectedProviderId &&
            connectionState == DeviceConnectionState.online &&
            _client != null &&
            _pendingConversationRefreshTurns[providerId]?.isNotEmpty == true) {
          final next =
              _pendingConversationRefreshTurns[providerId]!.values.first;
          unawaited(_refreshConversationsForEvent(providerId, next));
        }
      }
    }
  }

  void _ensureSelectedProviderLists() {
    for (final entry in _recentControllers.entries) {
      entry.value.setActive(entry.key == selectedProviderId);
    }
    final provider = selectedProvider;
    if (provider != null) _ensureProviderLists(provider);
  }

  void _ensureProviderLists(GatewayProvider provider) {
    if (provider.id != selectedProviderId) return;
    if (connectionState == DeviceConnectionState.online) {
      _ensureRecent(provider);
    }
    if (connectionState != DeviceConnectionState.online ||
        !provider.isAvailable ||
        !provider.capabilitiesLoaded) {
      return;
    }
    if (providerData(provider.id, ProviderDataKind.projects).status !=
            ProviderDataStatus.failed &&
        provider.methods.contains('project.list') &&
        (!_projectCursors.containsKey(provider.id) ||
            _pendingProjectRefreshes.contains(provider.id))) {
      if (!_projectRefreshes.containsKey(provider.id)) {
        _queueProjectRefresh(provider.id);
      }
    }
    final scope = _standaloneScope(provider);
    if (providerData(provider.id, ProviderDataKind.conversations).status !=
            ProviderDataStatus.failed &&
        provider.methods.contains('conversation.list') &&
        !_loadedConversationScopes.contains(scope)) {
      unawaited(_loadInitialProviderConversations(provider, scope));
    } else if (provider.methods.contains('conversation.list') &&
        providerData(provider.id, ProviderDataKind.conversations).status !=
            ProviderDataStatus.failed) {
      final pending = _pendingConversationRefreshTurns[provider.id];
      if (pending != null && pending.isNotEmpty) {
        unawaited(
          _refreshConversationsForEvent(provider.id, pending.values.first),
        );
      }
    }
  }

  Future<void> _loadInitialProviderConversations(
    GatewayProvider provider,
    _ConversationListScope scope,
  ) async {
    final client = _client;
    final generation = _runtimeGeneration;
    final epoch = _providerEpoch(provider.id);
    if (client == null || _initialConversationLoads.containsKey(scope)) return;
    final token = Object();
    _initialConversationLoads[scope] = token;
    final window = client.openEventWindow();
    _setProviderData(
      provider.id,
      ProviderDataKind.conversations,
      ProviderDataStatus.loading,
    );
    try {
      final page = await client
          .listConversations(
            providerId: provider.id,
            projectFilter: scope.filter,
            limit: DeviceSession.conversationPageSize,
          )
          .timeout(providerLoadTimeout);
      if (!_ownsProviderLoad(generation, client, provider.id, epoch)) return;
      final tail = _snapshotTail(window, page.snapshotCursor);
      conversations = mergeRoutedConversations(
        conversations,
        page.conversations,
      );
      _conversationCursors[scope] = page.nextCursor;
      _loadedConversationScopes.add(scope);
      _replayConversationTail(tail, provider.id);
      _setProviderData(
        provider.id,
        ProviderDataKind.conversations,
        ProviderDataStatus.ready,
      );
      onConversationSnapshot?.call(conversations);
      final pending = _pendingConversationRefreshTurns[provider.id];
      if (pending != null && pending.isNotEmpty) {
        unawaited(
          _refreshConversationsForEvent(provider.id, pending.values.first),
        );
      }
    } catch (error, stackTrace) {
      if (!_ownsProviderLoad(generation, client, provider.id, epoch)) return;
      _setProviderData(
        provider.id,
        ProviderDataKind.conversations,
        ProviderDataStatus.failed,
        error,
      );
      _logBackgroundWarning(
        'provider:${provider.id}',
        'Provider conversation loading failed',
        error,
        stackTrace,
      );
    } finally {
      if (identical(_initialConversationLoads[scope], token)) {
        _initialConversationLoads.remove(scope);
      }
      unawaited(_closeProviderWindow(window));
    }
  }

  void _queueProjectRefresh(String providerId) {
    _pendingProjectRefreshes.add(providerId);
    if (providerId != selectedProviderId) return;
    unawaited(_refreshProjectsForEvent(providerId));
  }

  Future<void> _refreshProjectsForEvent(String providerId) async {
    if (providerId != selectedProviderId ||
        _projectRefreshes.containsKey(providerId)) {
      return;
    }
    final token = Object();
    _projectRefreshes[providerId] = token;
    var continuePending = true;
    try {
      while (providerId == selectedProviderId &&
          _pendingProjectRefreshes.remove(providerId)) {
        final client = _client;
        final generation = _runtimeGeneration;
        final epoch = _providerEpoch(providerId);
        final provider = _providerForId(providerId);
        if (client == null ||
            connectionState != DeviceConnectionState.online ||
            provider?.isAvailable != true ||
            !provider!.capabilitiesLoaded ||
            !provider.methods.contains('project.list')) {
          return;
        }
        final window = client.openEventWindow();
        _setProviderData(
          providerId,
          ProviderDataKind.projects,
          ProviderDataStatus.loading,
        );
        try {
          if (client is! ProjectGatewayClient) {
            throw UnsupportedError(
              'Gateway adapter does not implement advertised project methods',
            );
          }
          final page = await (client as ProjectGatewayClient)
              .listProjects(
                providerId: providerId,
                limit: DeviceSession.conversationPageSize,
              )
              .timeout(providerLoadTimeout);
          if (!_ownsProviderLoad(generation, client, providerId, epoch)) return;
          final tail = _snapshotTail(window, page.snapshotCursor);
          projects = replaceProviderProjects(
            projects,
            providerId,
            page.projects,
          );
          _projectCursors[providerId] = page.nextCursor;
          for (final event in tail.whereType<ProjectChangedEvent>()) {
            if (event.project.providerId != providerId) continue;
            if (event.changeType == ProjectChangeType.deleted) {
              _removeProject(event.project);
            }
            _pendingProjectRefreshes.add(providerId);
          }
          _setProviderData(
            providerId,
            ProviderDataKind.projects,
            ProviderDataStatus.ready,
          );
        } catch (error, stackTrace) {
          continuePending = false;
          if (!_ownsProviderLoad(generation, client, providerId, epoch)) return;
          _pendingProjectRefreshes.add(providerId);
          _setProviderData(
            providerId,
            ProviderDataKind.projects,
            ProviderDataStatus.failed,
            error,
          );
          _logBackgroundWarning(
            'project:$providerId',
            'Project loading failed for device ${device.deviceId} provider=$providerId',
            error,
            stackTrace,
          );
          return;
        } finally {
          // The UI may retry as soon as failure is published. Releasing the
          // request gate must not wait for asynchronous stream cancellation.
          if (!continuePending &&
              identical(_projectRefreshes[providerId], token)) {
            _projectRefreshes.remove(providerId);
          }
          unawaited(_closeProviderWindow(window));
        }
      }
    } finally {
      // A retired request must not clear a replacement Provider's in-flight gate.
      if (identical(_projectRefreshes[providerId], token)) {
        _projectRefreshes.remove(providerId);
        if (continuePending &&
            providerId == selectedProviderId &&
            _pendingProjectRefreshes.contains(providerId)) {
          unawaited(_refreshProjectsForEvent(providerId));
        }
      }
    }
  }
}
