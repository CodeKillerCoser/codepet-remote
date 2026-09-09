import 'dart:async';
import 'dart:collection';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../core/domain/models.dart';
import '../application/errors/application_failures.dart';
import '../application/ports/gateway_client.dart';
import '../application/ports/recent_conversation_gateway.dart';
import '../application/ports/trace_recorder.dart';
import '../application/sync/gateway_event_window.dart';
import '../diagnostics/app_log.dart';
import '../diagnostics/gateway_protocol_instrumentation.dart';
import 'generated_gateway_mapper.dart';
import 'transport.dart';

final AppLog _log = AppLog.named('gateway.protocol');

/// Infrastructure adapter backed exclusively by CodePet's generated SDK.
final class ProtocolGatewayClient
    implements
        GatewayClient,
        ConversationResumeGatewayClient,
        ConversationHistoryGatewayClient,
        ProviderSnapshotGatewayClient,
        ConversationReadGatewayClient,
        ConversationControlGatewayClient,
        RecentConversationGateway,
        ProjectGatewayClient {
  ProtocolGatewayClient({
    required this.transport,
    required this.clientId,
    required this.clientDevice,
    required this.expectedDeviceId,
    required this.expectedIdentityFingerprint,
    this.clientVersion = '0.1.0',
    this.onValidatedEndpoint,
    this.onValidatedHostDescriptor,
    this.traceRecorder = const NoopTraceRecorder(),
  }) {
    _instrumentation = GatewayProtocolInstrumentation(traceRecorder);
    _protocol = sdk.ProtocolClient(
      transport,
      requestIdFactory: () => 'remote-${_nextRequestId++}',
      instrumentation: _instrumentation,
    );
  }

  final GatewayTransport transport;
  final String clientId;
  final DeviceDescriptor clientDevice;
  final String expectedDeviceId;
  final String expectedIdentityFingerprint;
  final String clientVersion;
  final FutureOr<void> Function(Uri endpoint)? onValidatedEndpoint;
  final FutureOr<void> Function(DeviceDescriptor descriptor)?
      onValidatedHostDescriptor;
  final TraceRecorder traceRecorder;

  static const _mapper = GeneratedGatewayMapper();
  static const _conversationHistoryPageLimits = [20, 10, 5, 1];
  late final GatewayProtocolInstrumentation _instrumentation;
  late final sdk.ProtocolClient _protocol;
  int _nextRequestId = 1;
  sdk.GatewayHeartbeatClient? _heartbeat;
  final _providerSnapshots = StreamController<List<GatewayProvider>>.broadcast(sync: true);
  final Map<String, int> _providerVersions = {};
  Map<String, int> _pingVersions = {};
  @override
  Stream<List<GatewayProvider>> get providerSnapshots => _providerSnapshots.stream;
  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast(sync: true);
  StreamSubscription<JsonMap>? _transportEvents;
  String? _latestEventCursor;
  final _BoundedCursorSet _seenEventCursors = _BoundedCursorSet();
  final Map<String, int> _receivedEventCounts = {};
  final Set<String> _tracedOutputTurns = {};
  int _duplicateEventCount = 0;
  Set<String> _providerIds = const {};
  final Map<String, GatewayProvider> _providersById = {};

  @override
  Stream<GatewayEvent> get events => _events.stream;

  @override
  String? get latestEventCursor => _latestEventCursor;

  @override
  GatewayEventWindow openEventWindow() =>
      GatewayEventWindow.forStream(_latestEventCursor, events);

  @override
  Future<GatewayHandshake> connect() async {
    _providerIds = const {};
    _providersById.clear();
    _transportEvents ??= transport.events.listen(
      (raw) {
        try {
          final envelope = sdk.ProtocolEventEnvelope.fromJson(raw);
          final event = _mapper.event(
            envelope,
            expectedDeviceId: expectedDeviceId,
            expectedProviderRouteKeys: _providerIds,
          );
          if (!_seenEventCursors.add(event.eventCursor)) {
            _duplicateEventCount++;
            if (_duplicateEventCount == 1 || _duplicateEventCount % 50 == 0) {
              _log.fine(
                'Duplicate Gateway events suppressed '
                'count=$_duplicateEventCount',
              );
            }
            return;
          }
          _logReceivedEvent(event);
          if (event is GatewayProviderChangedEvent) {
            _providersById[event.provider.id] = _mergeProviderSummary(event.provider);
            _providerIds = {..._providerIds, event.provider.id};
            _providerVersions.update(event.provider.id, (v) => v + 1, ifAbsent: () => 1);
          }
          _latestEventCursor = event.eventCursor;
          final traceContext = _traceCorrelation(envelope.traceContext);
          final shouldTraceEvent = event is! TurnOutputDeltaEvent ||
              _tracedOutputTurns.add(event.turnId);
          if (shouldTraceEvent) {
            traceRecorder.instant(
              'gateway.event.received',
              context: traceContext,
              attributes: {
                'event.name': envelope.event.toJson(),
                'event.cursor': event.eventCursor,
                if (event is TurnOutputDeltaEvent) ...{
                  'turn.id': event.turnId,
                  'delta.bytes': event.delta.length,
                  'sample': 'first-delta-per-turn',
                },
              },
            );
          }
          _events.add(traceContext == null
              ? event
              : ObservedGatewayEvent(
                  event: event,
                  traceContext: traceContext,
                  receivedAt: DateTime.now().toUtc(),
                ));
        } catch (error, stack) {
          final protocolError = error is FormatException
              ? error
              : FormatException('Invalid generated Gateway event: $error');
          _log.warning(
            'Gateway event rejected at protocol boundary '
            'method=${raw['method'] ?? 'unknown'}',
            error: protocolError,
            stackTrace: stack,
          );
          _events.addError(protocolError, stack);
        }
      },
      onError: _events.addError,
    );

    await transport.connect();
    final generated = await _call(
      () => _protocol.protocolHandshake(
        sdk.HandshakeRequest(
          clientId: clientId,
          device: sdk.DeviceDescriptor(
            deviceName: clientDevice.deviceName,
            operatingSystem: clientDevice.operatingSystem,
            systemVersion: clientDevice.systemVersion,
          ),
          clientVersion: clientVersion,
          supportedVersions: sdk.VersionRange(
            minVersion: sdk.protocolVersion,
            maxVersion: sdk.protocolVersion,
          ),
        ),
      ),
    );
    if (generated.protocol.version != sdk.protocolVersion) {
      await transport.close();
      throw const GatewayConnectionException(
        'Gateway identity mismatch',
        retryable: false,
      );
    }
    if (traceRecorder is! NoopTraceRecorder) {
      try {
        final description = await _call(
          () => _protocol.protocolDescribe(sdk.ProtocolDescribeRequest()),
        );
        _instrumentation.wirePropagationEnabled =
            description.features.contains(sdk.ProtocolFeature.traceContextV1);
      } on GatewayProtocolException catch (error) {
        if (error.code != 'gateway_rpc_-32601') rethrow;
        _instrumentation.wirePropagationEnabled = false;
      }
    }
    final providers = generated.providers
        .map(_mapper.provider)
        .toList(growable: false);
    _providerIds = providers.map((value) => value.id).toSet();
    _providersById.addEntries(
      providers.map((value) => MapEntry(value.id, value)),
    );
    final descriptor = DeviceDescriptor(
      deviceName: generated.device.name,
      operatingSystem: generated.device.operatingSystem,
      systemVersion: generated.device.systemVersion,
    );
    await onValidatedHostDescriptor?.call(descriptor);
    _seenEventCursors.add(generated.eventCursor);
    final subscription = await _call(
      () => _protocol.eventSubscribe(
        sdk.EventSubscribeRequest(afterCursor: generated.eventCursor),
      ),
    );
    if (subscription.subscribedAfterCursor != generated.eventCursor) {
      await transport.close();
      throw const GatewayConnectionException(
        'Gateway subscription cursor mismatch',
        retryable: false,
      );
    }
    _latestEventCursor ??= generated.eventCursor;
    final endpoint = transport is EndpointAwareGatewayTransport
        ? (transport as EndpointAwareGatewayTransport).selectedGatewayUri
        : null;
    final shouldPersistEndpoint =
        transport is EndpointPersistenceAwareGatewayTransport
            ? (transport as EndpointPersistenceAwareGatewayTransport)
                .shouldPersistSelectedGatewayUri
            : true;
    if (endpoint != null && shouldPersistEndpoint) {
      await onValidatedEndpoint?.call(endpoint);
    }
    _heartbeat = sdk.GatewayHeartbeatClient(
      client: _protocol,
      beforePing: () => _pingVersions = Map.of(_providerVersions),
      onProviders: (summaries) {
        final fresh = <String, GatewayProvider>{};
        for (final summary in summaries) {
          final previous = _providersById[summary.id];
          final changedDuringPing = _providerVersions[summary.id] != _pingVersions[summary.id];
          fresh[summary.id] = changedDuringPing && previous != null ? previous : _mergeProviderSummary(_mapper.provider(summary));
        }
        for (final entry in _providersById.entries) {
          if (_providerVersions[entry.key] != _pingVersions[entry.key]) fresh[entry.key] = entry.value;
        }
        _providersById..clear()..addAll(fresh);
        _providerIds = fresh.keys.toSet();
        _providerSnapshots.add(fresh.values.toList(growable: false));
      },
      onFailure: (error, stack) => _events.addError(
        GatewayConnectionException('Gateway heartbeat failed: $error', retryable: true), stack),
    )..start();
    return GatewayHandshake(
      protocolVersion: sdk.protocolVersion,
      providers: providers,
      eventCursor: generated.eventCursor,
      deviceDescriptor: descriptor,
    );
  }

  GatewayProvider _mergeProviderSummary(GatewayProvider incoming) {
    final previous = _providersById[incoming.id];
    if (previous == null) return incoming;
    if (previous.generation != null && incoming.generation != null && incoming.generation! < previous.generation!) return previous;
    if (previous.capabilitiesLoaded && previous.generation == incoming.generation &&
        previous.capabilities.revision == incoming.capabilities.revision) {
      return incoming.withCapabilities(previous.capabilities);
    }
    return incoming;
  }

  void _logReceivedEvent(GatewayEvent event) {
    final eventType = event.runtimeType.toString();
    final count = (_receivedEventCounts[eventType] ?? 0) + 1;
    _receivedEventCounts[eventType] = count;
    if (event is TurnOutputDeltaEvent) {
      if (count == 1 || count % 100 == 0) {
        _log.fine(
          'Gateway output delta events received count=$count',
        );
      }
      return;
    }
    _log.fine('Gateway event received type=$eventType count=$count');
  }

  @override
  Future<GatewayProvider> describeProvider(String providerId) async {
    _requireProviderId(providerId);
    final response = await _call(
      () => _protocol.providerDescribe(
        sdk.ProviderDescribeRequest(providerId: providerId),
      ),
    );
    if (response.provider.id != providerId ||
        response.capabilities.revision !=
            response.provider.capabilities.revision) {
      throw const FormatException('provider.describe returned stale identity');
    }
    final provider = _mapper.provider(
      response.provider,
      capabilities: response.capabilities,
    );
    _providersById[providerId] = provider;
    return provider;
  }

  @override
  Future<RecentConversationPage> recentConversations({
    required String providerId,
    String? cursor,
    int limit = 20,
  }) async {
    await _requireProviderCapability(
      providerId, method: 'conversation.recent', cursor: cursor, limit: limit,
    );
    final response = await _call(() => _protocol.conversationRecent(
      sdk.ConversationRecentRequest(providerId: providerId, cursor: cursor, limit: limit),
    ));
    if (response.conversations.any((conversation) => conversation.readState == null)) {
      throw const FormatException('conversation.recent omitted authoritative readState');
    }
    final page = _conversationPage(
      conversations: response.conversations,
      nextCursor: response.pageInfo.nextCursor,
      snapshotCursor: response.snapshotCursor,
      providerId: providerId,
      method: 'conversation.recent',
    );
    return RecentConversationPage(
      conversations: page.conversations,
      nextCursor: page.nextCursor,
      revision: response.revision,
      snapshotCursor: page.snapshotCursor,
    );
  }

  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    if (projectFilter case ProjectConversationFilter(:final project)) {
      if (project.providerId != providerId) {
        throw const FormatException(
          'Conversation project filter providerId does not match Provider providerId',
        );
      }
    }
    await _requireProviderCapability(
      providerId,
      method: 'conversation.list',
      cursor: cursor,
      limit: limit,
    );
    final response = await _call(
      () => _protocol.conversationList(
        sdk.ConversationListRequest(
          providerId: providerId,
          projectFilter: _mapper.conversationProjectFilter(projectFilter),
          cursor: cursor,
          limit: limit,
        ),
      ),
    );
    return _conversationPage(
      conversations: response.conversations,
      nextCursor: response.pageInfo.nextCursor,
      snapshotCursor: response.snapshotCursor,
      providerId: providerId,
      method: 'conversation.list',
    );
  }

  @override
  Future<ProjectPage> listProjects({
    required String providerId,
    String? cursor,
    int limit = 50,
  }) async {
    await _requireProviderCapability(
      providerId,
      method: 'project.list',
      cursor: cursor,
      limit: limit,
    );
    final response = await _call(
      () => _protocol.projectList(
        sdk.ProjectListRequest(
          providerId: providerId,
          cursor: cursor,
          limit: limit,
        ),
      ),
    );
    final projects = response.projects.map((project) {
      _requireSdkResourceRoute(project.resource, providerId, 'project.list');
      return _mapper.project(project);
    }).toList(growable: false);
    return ProjectPage(
      projects: projects,
      nextCursor: response.pageInfo.nextCursor,
      snapshotCursor: response.snapshotCursor,
    );
  }

  @override
  Future<GatewayProject> getProject(RoutedResourceId project) async {
    final providerId = project.providerId;
    await _requireProviderCapability(providerId, method: 'project.get');
    final requested = _mapper.sdkResourceId(project);
    final response = await _call(
      () => _protocol.projectGet(sdk.ProjectGetRequest(project: requested)),
    );
    _requireSameSdkResource(
      response.project.resource,
      requested,
      'project.get',
    );
    return _mapper.project(response.project);
  }

  @override
  Future<GatewayProject> createProject({
    required String providerId,
    required String idempotencyKey,
    required String name,
    required List<ProjectRoot> roots,
    Map<String, String> metadata = const {},
  }) async {
    await _requireProviderCapability(providerId, method: 'project.create');
    final response = await _call(
      () => _protocol.projectCreate(
        sdk.ProjectCreateRequest(
          providerId: providerId,
          idempotencyKey: idempotencyKey,
          name: name,
          roots: _mapper.projectRoots(roots),
          metadata: metadata,
        ),
      ),
    );
    _requireSdkResourceRoute(response.project.resource, providerId, 'project.create');
    return _mapper.project(response.project);
  }

  @override
  Future<GatewayProject> updateProject({
    required RoutedResourceId project,
    String? name,
    List<ProjectRoot>? roots,
    Map<String, String>? metadata,
  }) async {
    if (name == null && roots == null && metadata == null) {
      throw const FormatException('project.update requires a changed field');
    }
    await _requireProviderCapability(
      project.providerId,
      method: 'project.update',
    );
    final requested = _mapper.sdkResourceId(project);
    final response = await _call(
      () => _protocol.projectUpdate(
        sdk.ProjectUpdateRequest(
          project: requested,
          name: name,
          roots: roots == null ? null : _mapper.projectRoots(roots),
          metadata: metadata,
        ),
      ),
    );
    _requireSameSdkResource(
      response.project.resource,
      requested,
      'project.update',
    );
    return _mapper.project(response.project);
  }

  @override
  Future<void> deleteProject(RoutedResourceId project) async {
    await _requireProviderCapability(
      project.providerId,
      method: 'project.delete',
    );
    await _call(
      () => _protocol.projectDelete(
        sdk.ProjectDeleteRequest(project: _mapper.sdkResourceId(project)),
      ),
    );
  }

  @override
  Future<ConversationPage> searchConversations({
    required String providerId,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  }) async {
    if (searchTerm.trim().isEmpty) {
      throw ArgumentError.value(searchTerm, 'searchTerm', 'must not be empty');
    }
    await _requireProviderCapability(
      providerId,
      method: 'conversation.search',
      cursor: cursor,
      limit: limit,
    );
    final response = await _call(
      () => _protocol.conversationSearch(
        sdk.ConversationSearchRequest(
          providerId: providerId,
          searchTerm: searchTerm,
          cursor: cursor,
          limit: limit,
        ),
      ),
    );
    return _conversationPage(
      conversations: response.conversations,
      nextCursor: response.pageInfo.nextCursor,
      snapshotCursor: response.snapshotCursor,
      providerId: providerId,
      method: 'conversation.search',
    );
  }

  ConversationPage _conversationPage({
    required List<sdk.Conversation> conversations,
    required String? nextCursor,
    required String snapshotCursor,
    required String providerId,
    required String method,
  }) {
    final mapped = conversations.map((conversation) {
      final resource = conversation.resource;
      if (resource.providerId != providerId) {
        throw FormatException('$method returned a different Provider providerId');
      }
      return _mapper.conversation(conversation);
    }).toList(growable: false);
    return ConversationPage(
      conversations: mapped,
      nextCursor: nextCursor,
      snapshotCursor: snapshotCursor,
    );
  }

  void _validateProviderRequest(
    String providerId, {
    required String? cursor,
    required int limit,
  }) {
    if (!_providerIds.contains(providerId)) {
      throw const FormatException(
        'Provider providerId does not belong to the connected Host handshake',
      );
    }
    if (cursor != null && cursor.isEmpty) {
      throw const FormatException('Gateway cursor must not be empty');
    }
    if (limit < 1 || limit > 100) {
      throw RangeError.range(limit, 1, 100, 'limit');
    }
  }

  Future<GatewayProvider> _requireProviderCapability(
    String providerId, {
    required String method,
    String? cursor,
    int limit = 1,
  }) async {
    _validateProviderRequest(providerId, cursor: cursor, limit: limit);
    var provider = _providersById[providerId];
    if (provider != null && !provider.capabilitiesLoaded) {
      provider = await describeProvider(providerId);
    }
    if (provider == null || !provider.methods.contains(method)) {
      throw FormatException('Provider $method capability is unavailable');
    }
    return provider;
  }

  void _requireSdkResourceRoute(
    sdk.RoutedResourceId resource,
    String providerId,
    String method,
  ) {
    if (resource.providerId != providerId) {
      throw FormatException('$method returned a different Provider providerId');
    }
  }

  void _requireProviderId(String providerId) {
    if (providerId.isEmpty || !_providerIds.contains(providerId)) {
      throw const FormatException(
        'Provider id does not belong to the connected Host handshake',
      );
    }
  }

  void _requireSameSdkResource(
    sdk.RoutedResourceId actual,
    sdk.RoutedResourceId expected,
    String method,
  ) {
    if (_mapper.resourceKey(actual) != _mapper.resourceKey(expected)) {
      throw FormatException('$method returned a different project');
    }
  }

  @override
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) => _readConversationHistory(conversation);

  @override
  Future<ConversationSnapshot> getConversationPage(
    ConversationSummary conversation, {
    required String cursor,
  }) => _readConversationHistory(conversation, cursor: cursor);

  Future<ConversationSnapshot> _readConversationHistory(
    ConversationSummary conversation, {
    String? cursor,
    sdk.ConversationGetResponse? firstPage,
    GatewayProtocolException? firstPageError,
  }) async {
    final totalStopwatch = Stopwatch()..start();
    final resourceId = conversation.resource;
    if (resourceId == null) {
      throw const FormatException('Conversation has no routed identity');
    }
    final requested = _mapper.sdkResourceId(resourceId);
    var pageLimitIndex = 0;
    const pageCount = 1;
    var requestCount = 0;
    var oversizedRetryCount = 0;
    sdk.ConversationGetResponse response;
    var pageAttempt = 0;
    while (true) {
      pageAttempt++;
      final fromResume = firstPage != null || firstPageError != null;
      if (!fromResume) requestCount++;
      final limit = _conversationHistoryPageLimits[pageLimitIndex];
      final requestStopwatch = Stopwatch()..start();
      _log.fine(
        'Conversation history page ${fromResume ? 'reused from resume' : 'requested'} '
        'conversation=${conversation.id} page=$pageCount attempt=$pageAttempt '
        'cursor=${cursor == null ? 'initial' : 'present'} '
        'cursorChars=${cursor == null ? 0 : cursor.length} limit=$limit',
      );
      try {
        if (firstPageError != null) {
          final error = firstPageError;
          firstPageError = null;
          throw error;
        }
        if (firstPage != null) {
          response = firstPage;
          firstPage = null;
        } else {
          response = await _call(
            () => _protocol.conversationGet(
              sdk.ConversationGetRequest(
                conversation: requested,
                cursor: cursor,
                limit: limit,
              ),
            ),
          );
        }
        _log.fine(
          'Conversation history page received '
          'conversation=${conversation.id} page=$pageCount attempt=$pageAttempt '
          'cursor=${cursor == null ? 'initial' : 'present'} limit=$limit '
          'items=${response.items.length} '
          'hasNextCursor=${response.pageInfo?.nextCursor != null} '
          'elapsedMs=${requestStopwatch.elapsedMilliseconds}',
        );
        break;
      } on GatewayProtocolException catch (error) {
        if (error.code != 'provider_response_too_large' ||
            pageLimitIndex == _conversationHistoryPageLimits.length - 1) {
          _log.warning(
            'Conversation history page failed '
            'conversation=${conversation.id} page=$pageCount '
            'attempt=$pageAttempt cursor=${cursor == null ? 'initial' : 'present'} '
            'limit=$limit elapsedMs=${requestStopwatch.elapsedMilliseconds} '
            'code=${error.code}',
            error: error,
          );
          rethrow;
        }
        oversizedRetryCount++;
        pageLimitIndex++;
        _log.fine(
          'Conversation history page exceeded transport limit; retrying '
          'conversation=${conversation.id} page=$pageCount '
          'attempt=$pageAttempt cursor=${cursor == null ? 'initial' : 'present'} '
          'previousLimit=$limit '
          'nextLimit=${_conversationHistoryPageLimits[pageLimitIndex]} '
          'elapsedMs=${requestStopwatch.elapsedMilliseconds} '
          'retryCount=$oversizedRetryCount',
        );
      }
    }

    final returned = response.conversation.resource;
    if (_mapper.resourceKey(returned) != _mapper.resourceKey(requested) ||
        returned.providerId != requested.providerId) {
      throw const FormatException(
        'conversation.get returned a different routed conversation',
      );
    }
    final responseActiveTurn = response.conversation.activeTurn;
    if (responseActiveTurn != null &&
        (_mapper.resourceKey(responseActiveTurn.conversation) !=
                _mapper.resourceKey(requested) ||
            !_mapper.hasSameRoute(responseActiveTurn.resource, requested))) {
      throw const FormatException('Conversation active turn providerId mismatch');
    }
    for (final item in response.items) {
      final approval = _mapper.itemApproval(item);
      final itemConversation = _mapper.itemConversation(item);
      final itemResource = _mapper.itemResource(item);
      final itemTurn = _mapper.itemTurn(item);
      final relatedItem = _mapper.itemRelatedItem(item);
      if (_mapper.resourceKey(itemConversation) !=
              _mapper.resourceKey(requested) ||
          !_mapper.hasSameRoute(itemResource, requested) ||
          !_mapper.hasSameRoute(itemTurn, requested) ||
          (relatedItem != null &&
              !_mapper.hasSameRoute(relatedItem, requested)) ||
          (approval != null &&
              (_mapper.resourceKey(approval.conversation) !=
                      _mapper.resourceKey(requested) ||
                  _mapper.resourceKey(approval.turn) !=
                      _mapper.resourceKey(itemTurn) ||
                  !_mapper.hasSameRoute(approval.resource, requested)))) {
        throw const FormatException('Conversation history providerId mismatch');
      }
    }

    final summary = _mapper.conversation(response.conversation);
    final activeTurn = responseActiveTurn == null ? null : _mapper.turn(responseActiveTurn);
    final snapshotCursor = response.snapshotCursor;
    final nextCursor = response.pageInfo?.nextCursor;
    if (nextCursor != null && nextCursor == cursor) {
      throw const FormatException('conversation.get returned a repeated page cursor');
    }
    final mappingStopwatch = Stopwatch()..start();
    final committedMessages = [
      for (var index = 0; index < response.items.length; index++)
        _mapper.message(response.items[index], index),
    ];
    final snapshot = ConversationSnapshot(
      detail: ConversationDetail(
        summary: summary,
        committedMessages: committedMessages,
        turns: [?activeTurn],
        lastEventCursor: snapshotCursor,
      ),
      snapshotCursor: snapshotCursor,
      nextCursor: nextCursor,
    );
    _log.fine(
      'Conversation history assembled conversation=${conversation.id} '
      'pages=$pageCount requests=$requestCount '
      'oversizedRetries=$oversizedRetryCount items=${response.items.length} '
      'messages=${committedMessages.length} '
      'mappingUs=${mappingStopwatch.elapsedMicroseconds} '
      'elapsedMs=${totalStopwatch.elapsedMilliseconds}',
    );
    return snapshot;
  }

  @override
  Future<ConversationReadState> markConversationRead(
    ConversationSummary conversation,
  ) async {
    final resource = conversation.resource;
    if (resource == null) {
      throw const FormatException('Conversation has no routed identity');
    }
    final response = await _call(
      () => _protocol.conversationMarkRead(
        sdk.ConversationMarkReadRequest(
          conversation: _mapper.sdkResourceId(resource),
          observedActivityVersion: conversation.readState.activityVersion,
        ),
      ),
    );
    return ConversationReadState(
      unread: response.readState.unread,
      activityVersion: response.readState.activityVersion,
    );
  }

  @override
  Future<ConversationResumeResult> resumeConversation(
    ConversationSummary conversation, {
    bool force = false,
  }) async {
    final resource = conversation.resource;
    if (resource == null) {
      throw const FormatException('Conversation has no routed identity');
    }
    final response = await _call(
      () => _protocol.conversationResume(sdk.ConversationResumeRequest(
        conversation: _mapper.sdkResourceId(resource),
        limit: _conversationHistoryPageLimits.first,
        force: force ? true : null,
      )),
    );
    if (response.interactionAcquired != (response.interaction != null) ||
        (response.interactionAcquired && response.interactionError != null) ||
        (response.history != null && response.historyError != null) ||
        (response.interactionAcquired && response.history == null && response.historyError == null)) {
      throw const FormatException('Invalid conversation.resume result');
    }
    final interaction = response.interaction;
    final historyError = response.historyError;
    return ConversationResumeResult(
      interaction: interaction == null ? null : _mapInteraction(interaction),
      interactionError: response.interactionError == null
          ? null : _mapProtocolError(response.interactionError!),
      loadHistory: response.history == null && historyError == null ? null : () =>
          _readConversationHistory(
            conversation,
            firstPage: response.history,
            firstPageError: historyError == null ? null : _mapProtocolError(historyError),
          ),
    );
  }

  GatewayProtocolException _mapProtocolError(sdk.ProtocolError error) =>
      GatewayProtocolException(
        code: error.code,
        message: error.message,
        retryable: error.retryable,
        details: error.details == null ? null : Map<String, dynamic>.from(error.details!),
      );

  @override
  Future<ConversationInteraction> acquireInteraction(
    ConversationSummary conversation,
  ) async {
    final resourceId = conversation.resource;
    if (resourceId == null) {
      throw const FormatException('Conversation has no routed identity');
    }
    final requested = _mapper.sdkResourceId(resourceId);
    final response = await _call(
      () => _protocol.conversationAcquireInteraction(
        sdk.ConversationAcquireInteractionRequest(conversation: requested),
      ),
    );
    return _mapInteraction(response);
  }

  ConversationInteraction _mapInteraction(sdk.ConversationAcquireInteractionResponse response) =>
      ConversationInteraction(
      selection: TurnSendSelection.fromJson(
        Map<String, dynamic>.from(response.selection.toJson()),
      ),
      leaseExpiresAt: response.leaseExpiresAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              response.leaseExpiresAt!,
              isUtc: true,
            ),
      );

  @override
  Future<ConversationSummary> createConversation({
    required String providerId,
    String? title,
    required String permissionLevel,
    String? model,
    String? reasoningEffort,
    String? workspaceRoot,
    String? workspaceMode,
    RoutedResourceId? project,
  }) async {
    if (project != null && project.providerId != providerId) {
      throw const FormatException(
        'Conversation project providerId does not match Provider providerId',
      );
    }
    final provider = await _requireProviderCapability(
      providerId,
      method: 'conversation.create',
    );
    if (!provider.isAvailable ||
        !provider.methods.contains('conversation.create')) {
      throw const FormatException(
        'Provider conversation.create capability is unavailable',
      );
    }
    final response = await _call(
      () => _protocol.conversationCreate(
        sdk.ConversationCreateRequest(
          providerId: providerId,
          title: title,
          permissionLevel: permissionLevel,
          model: model,
          reasoningEffort: reasoningEffort,
          workspaceRoot: workspaceRoot,
          workspaceMode: workspaceMode,
          project: project == null ? null : _mapper.sdkResourceId(project),
        ),
      ),
    );
    _mapper.requireExpectedResource(
      response.conversation.resource,
      expectedDeviceId: expectedDeviceId,
      expectedProviderRouteKeys: _providerIds,
    );
    if (response.conversation.resource.providerId != providerId) {
      throw const FormatException(
        'conversation.create returned a different Provider providerId',
      );
    }
    return _mapper.conversation(response.conversation);
  }

  @override
  Future<TurnSendReceipt> sendTurn({
    required String providerId,
    required ConversationSummary conversation,
    required String clientRequestId,
    required String capabilityRevision,
    required String text,
    required TurnSendSelection selection,
  }) async {
    if (clientRequestId.isEmpty) {
      throw ArgumentError.value(
        clientRequestId,
        'clientRequestId',
        'must not be empty',
      );
    }
    if (capabilityRevision.isEmpty) {
      throw ArgumentError.value(
        capabilityRevision,
        'capabilityRevision',
        'must not be empty',
      );
    }
    if (text.trim().isEmpty) {
      throw ArgumentError.value(text, 'text', 'must not be blank');
    }
    final provider = await _requireProviderCapability(
      providerId,
      method: 'turn.send',
    );
    if (!provider.isAvailable ||
        !provider.methods.contains('turn.send') ||
        provider.capabilities.revision != capabilityRevision ||
        provider.capabilities.turnSend == null) {
      throw const FormatException(
        'Provider turn.send capability is unavailable or stale',
      );
    }
    if (!provider.capabilities.turnSend!.accepts(selection)) {
      throw const FormatException('Turn selection is invalid or unavailable');
    }
    final resourceId = conversation.resource;
    if (resourceId == null) {
      throw const FormatException('Conversation has no routed identity');
    }
    final resource = _mapper.sdkResourceId(resourceId);
    if (resource.providerId != providerId) {
      throw const FormatException(
        'Conversation providerId does not match turn.send Provider providerId',
      );
    }
    final response = await _call(
      () => _protocol.turnSend(
        sdk.TurnSendRequest(
          conversation: resource,
          clientRequestId: clientRequestId,
          capabilityRevision: capabilityRevision,
          input: sdk.TurnInput(kind: sdk.TurnInputKind.text, text: text),
          selection: sdk.TurnSelection.fromJson(selection.toJson()),
        ),
      ),
    );
    final userItem = response.userItem;
    final effectiveSelection = _mapper.selection(response.effectiveSelection);
    if (!response.accepted ||
        _mapper.resourceKey(response.turn.conversation) !=
            _mapper.resourceKey(resource) ||
        !_mapper.hasSameRoute(response.turn.resource, resource) ||
        (userItem != null &&
            (_mapper.resourceKey(_mapper.itemConversation(userItem)) !=
                    _mapper.resourceKey(resource) ||
                _mapper.resourceKey(_mapper.itemTurn(userItem)) !=
                    _mapper.resourceKey(response.turn.resource) ||
                !_mapper.hasSameRoute(
                  _mapper.itemResource(userItem),
                  resource,
                ) ||
                !_mapper.isUserMessage(userItem))) ||
        !provider.capabilities.turnSend!.accepts(effectiveSelection)) {
      throw const FormatException('Invalid routed turn.send response');
    }
    return TurnSendReceipt(
      clientRequestId: clientRequestId,
      turn: _mapper.turn(response.turn),
      inputItem: userItem == null
          ? null
          : _mapper.message(
              userItem,
              DateTime.now().toUtc().millisecondsSinceEpoch,
            ),
      effectiveSelection: effectiveSelection,
    );
  }

  @override
  Future<TurnTask> interruptTurn({
    required ConversationSummary conversation,
    required TurnTask turn,
  }) async {
    final provider = await _requireProviderCapability(
      conversation.providerId,
      method: 'turn.interrupt',
    );
    if (!provider.isAvailable ||
        !provider.methods.contains('turn.interrupt')) {
      throw const FormatException('Provider turn.interrupt capability is unavailable');
    }
    final conversationResource = conversation.resource;
    final turnResource = turn.resource;
    if (conversationResource == null || turnResource == null) {
      throw const FormatException('Conversation or turn has no routed identity');
    }
    if (conversationResource.providerId != turnResource.providerId ||
        conversationResource.providerId != conversation.providerId ||
        turn.conversationResource != conversationResource) {
      throw const FormatException('Turn does not belong to the conversation');
    }
    final response = await _call(() => _protocol.turnInterrupt(
          sdk.TurnInterruptRequest(
            conversation: _mapper.sdkResourceId(conversationResource),
            turn: _mapper.sdkResourceId(turnResource),
          ),
        ));
    final interrupted = _mapper.turn(response.turn);
    if (interrupted.id != turn.id || interrupted.conversationId != conversation.id) {
      throw const FormatException('turn.interrupt returned a different routed turn');
    }
    return interrupted;
  }

  @override
  Future<GatewayMessage> resolveApproval({
    required GatewayMessage approval,
    required ApprovalDecision decision,
  }) async {
    final resource = approval.resource;
    if (resource == null || approval.kind != 'approval') {
      throw const FormatException('Approval has no routed identity');
    }
    final provider = await _requireProviderCapability(
      resource.providerId,
      method: 'approval.resolve',
    );
    if (!provider.isAvailable ||
        !provider.methods.contains('approval.resolve') ||
        approval.approvalStatus != 'pending' ||
        !approval.approvalDecisions.contains(decision)) {
      throw const FormatException('Provider approval.resolve capability is unavailable or invalid');
    }
    final response = await _call(() => _protocol.approvalResolve(
          sdk.ApprovalResolveRequest(
            approval: _mapper.sdkResourceId(resource),
            decision: switch (decision) {
              ApprovalDecision.approve => sdk.ApprovalDecision.approve,
              ApprovalDecision.deny => sdk.ApprovalDecision.deny,
            },
          ),
        ));
    for (final routed in [
      response.approval.resource,
      response.approval.conversation,
      response.approval.turn,
    ]) {
      _mapper.requireExpectedResource(
        routed,
        expectedDeviceId: expectedDeviceId,
        expectedProviderRouteKeys: _providerIds,
      );
    }
    if (!_mapper.hasSameRoute(response.approval.resource, response.approval.conversation) ||
        !_mapper.hasSameRoute(response.approval.resource, response.approval.turn) ||
        _mapper.resourceKey(response.approval.resource) != approval.id) {
      throw const FormatException('Invalid routed approval.resolve response');
    }
    return _mapper.approval(response.approval);
  }

  @override
  Future<void> close() async {
    _heartbeat?.close();
    await _providerSnapshots.close();
    _providerIds = const {};
    _providersById.clear();
    await _transportEvents?.cancel();
    _transportEvents = null;
    await transport.close();
    await _events.close();
  }

  Future<T> _call<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on sdk.ProtocolRemoteException catch (error) {
      final data = error.error.data;
      throw GatewayProtocolException(
        code: data?['code'] is String
            ? data!['code'] as String
            : 'gateway_rpc_${error.error.code}',
        message: error.error.message,
        retryable: data?['retryable'] == true,
        details: data == null ? null : Map<String, dynamic>.from(data),
      );
    } on sdk.ProtocolCodecException catch (error) {
      throw FormatException(error.toString());
    }
  }
}

TraceCorrelation? _traceCorrelation(sdk.TraceContext? context) => context == null
    ? null
    : TraceCorrelation.tryParse(
        context.traceparent,
        traceState: context.tracestate,
      );

class _BoundedCursorSet {
  static const capacity = 512;
  final Set<String> _values = {};
  final Queue<String> _arrivalOrder = Queue<String>();

  bool add(String cursor) {
    if (!_values.add(cursor)) return false;
    _arrivalOrder.addLast(cursor);
    while (_arrivalOrder.length > capacity) {
      _values.remove(_arrivalOrder.removeFirst());
    }
    return true;
  }
}
