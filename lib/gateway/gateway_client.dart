import 'dart:async';
import 'dart:collection';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../core/domain/models.dart';
import '../application/errors/application_failures.dart';
import '../application/ports/gateway_client.dart';
import '../application/sync/gateway_event_window.dart';
import 'generated_gateway_mapper.dart';
import 'transport.dart';

/// Infrastructure adapter backed exclusively by CodePet's generated SDK.
final class ProtocolGatewayClient
    implements GatewayClient, ConversationReadGatewayClient {
  ProtocolGatewayClient({
    required this.transport,
    required this.clientId,
    required this.clientDevice,
    required this.expectedDeviceId,
    required this.expectedIdentityFingerprint,
    this.clientVersion = '0.1.0',
    this.onValidatedEndpoint,
    this.onValidatedHostDescriptor,
  }) {
    _protocol = sdk.ProtocolClient(
      transport,
      requestIdFactory: () => 'remote-${_nextRequestId++}',
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

  static const _mapper = GeneratedGatewayMapper();
  late final sdk.ProtocolClient _protocol;
  int _nextRequestId = 1;
  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast(sync: true);
  StreamSubscription<JsonMap>? _transportEvents;
  String? _latestEventCursor;
  final _BoundedCursorSet _seenEventCursors = _BoundedCursorSet();
  Set<String> _providerRouteKeys = const {};
  final Map<String, GatewayProvider> _providersByRoute = {};

  @override
  Stream<GatewayEvent> get events => _events.stream;

  @override
  String? get latestEventCursor => _latestEventCursor;

  @override
  GatewayEventWindow openEventWindow() =>
      GatewayEventWindow.forStream(_latestEventCursor, events);

  @override
  Future<GatewayHandshake> connect() async {
    _providerRouteKeys = const {};
    _providersByRoute.clear();
    _transportEvents ??= transport.events.listen(
      (raw) {
        try {
          final envelope = sdk.ProtocolEventEnvelope.fromJson(raw);
          final event = _mapper.event(
            envelope,
            expectedDeviceId: expectedDeviceId,
            expectedProviderRouteKeys: _providerRouteKeys,
          );
          if (!_seenEventCursors.add(event.eventCursor)) return;
          if (event is GatewayProviderChangedEvent) {
            _providersByRoute[event.provider.route.key] = event.provider;
          }
          _latestEventCursor = event.eventCursor;
          _events.add(event);
        } catch (error, stack) {
          final protocolError = error is FormatException
              ? error
              : FormatException('Invalid generated Gateway event: $error');
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
    if (generated.selectedVersion != sdk.protocolVersion ||
        generated.device.deviceId != expectedDeviceId) {
      await transport.close();
      throw const GatewayConnectionException(
        'Gateway identity mismatch',
        retryable: false,
      );
    }
    final providers = generated.providers.map((value) {
      final provider = _mapper.provider(value);
      if (provider.route.deviceId != expectedDeviceId) {
        throw const FormatException(
          'Provider route does not belong to the connected Host',
        );
      }
      return provider;
    }).toList(growable: false);
    _providerRouteKeys = providers.map((value) => value.route.key).toSet();
    _providersByRoute.addEntries(
      providers.map((value) => MapEntry(value.route.key, value)),
    );
    final descriptor = DeviceDescriptor(
      deviceName: generated.device.descriptor.deviceName,
      operatingSystem: generated.device.descriptor.operatingSystem,
      systemVersion: generated.device.descriptor.systemVersion,
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
    return GatewayHandshake(
      protocolVersion: sdk.protocolVersion,
      serverName: generated.serverName,
      serverVersion: generated.serverVersion,
      providers: providers,
      eventCursor: generated.eventCursor,
      deviceId: generated.device.deviceId,
      identityFingerprint: expectedIdentityFingerprint,
      deviceDescriptor: descriptor,
    );
  }

  @override
  Future<ConversationPage> listConversations({
    required GatewayProviderRoute route,
    String? cursor,
    int limit = 50,
  }) async {
    _validateProviderRequest(route, cursor: cursor, limit: limit);
    final response = await _call(
      () => _protocol.conversationList(
        sdk.ConversationListRequest(
          route: _mapper.sdkProviderRoute(route),
          cursor: cursor,
          limit: limit,
        ),
      ),
    );
    return _conversationPage(
      conversations: response.conversations,
      nextCursor: response.pageInfo.nextCursor,
      snapshotCursor: response.snapshotCursor,
      route: route,
      method: 'conversation.list',
    );
  }

  @override
  Future<ConversationPage> searchConversations({
    required GatewayProviderRoute route,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  }) async {
    if (searchTerm.trim().isEmpty) {
      throw ArgumentError.value(searchTerm, 'searchTerm', 'must not be empty');
    }
    _validateProviderRequest(route, cursor: cursor, limit: limit);
    final response = await _call(
      () => _protocol.conversationSearch(
        sdk.ConversationSearchRequest(
          route: _mapper.sdkProviderRoute(route),
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
      route: route,
      method: 'conversation.search',
    );
  }

  ConversationPage _conversationPage({
    required List<sdk.Conversation> conversations,
    required String? nextCursor,
    required String snapshotCursor,
    required GatewayProviderRoute route,
    required String method,
  }) {
    final mapped = conversations.map((conversation) {
      final resource = conversation.resource;
      if (resource.deviceId != route.deviceId ||
          resource.providerPluginId != route.providerPluginId ||
          resource.providerInstanceId != route.providerInstanceId) {
        throw FormatException('$method returned a different Provider route');
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
    GatewayProviderRoute route, {
    required String? cursor,
    required int limit,
  }) {
    if (route.deviceId != expectedDeviceId ||
        !_providerRouteKeys.contains(route.key)) {
      throw const FormatException(
        'Provider route does not belong to the connected Host handshake',
      );
    }
    if (cursor != null && cursor.isEmpty) {
      throw const FormatException('Gateway cursor must not be empty');
    }
    if (limit < 1 || limit > 100) {
      throw RangeError.range(limit, 1, 100, 'limit');
    }
  }

  @override
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) async {
    final resourceId = conversation.resource;
    if (resourceId == null) {
      throw const FormatException('Conversation has no routed identity');
    }
    final requested = _mapper.sdkResourceId(resourceId);
    const desiredLimit = 40;
    var effectiveLimit = desiredLimit;
    String? cursor;
    final seenCursors = <String>{};
    final pages = <List<sdk.ConversationItem>>[];
    ConversationSummary? summary;
    TurnTask? activeTurn;
    String? snapshotCursor;
    var pageCount = 0;

    while (true) {
      pageCount++;
      if (pageCount > 10000) {
        throw const FormatException(
          'conversation.get exceeded the 10000-page safety limit',
        );
      }
      sdk.ConversationGetResponse response;
      while (true) {
        try {
          response = await _call(
            () => _protocol.conversationGet(
              sdk.ConversationGetRequest(
                conversation: requested,
                cursor: cursor,
                limit: effectiveLimit,
              ),
            ),
          );
          break;
        } on GatewayProtocolException catch (error) {
          if (error.code != 'provider_response_too_large' ||
              effectiveLimit == 1) {
            rethrow;
          }
          effectiveLimit = effectiveLimit ~/ 2;
        }
      }

      final returned = response.conversation.resource;
      if (_mapper.resourceKey(returned) != _mapper.resourceKey(requested) ||
          returned.deviceId != expectedDeviceId) {
        throw const FormatException(
          'conversation.get returned a different routed conversation',
        );
      }
      final responseActiveTurn = response.conversation.activeTurn;
      if (responseActiveTurn != null &&
          (_mapper.resourceKey(responseActiveTurn.conversation) !=
                  _mapper.resourceKey(requested) ||
              !_mapper.hasSameRoute(responseActiveTurn.resource, requested))) {
        throw const FormatException('Conversation active turn route mismatch');
      }
      for (final item in response.items) {
        final approval = item.approval;
        if (_mapper.resourceKey(item.conversation) !=
                _mapper.resourceKey(requested) ||
            !_mapper.hasSameRoute(item.resource, requested) ||
            !_mapper.hasSameRoute(item.turn, requested) ||
            (item.relatedItem != null &&
                !_mapper.hasSameRoute(item.relatedItem!, requested)) ||
            (approval != null &&
                (_mapper.resourceKey(approval.conversation) !=
                        _mapper.resourceKey(requested) ||
                    _mapper.resourceKey(approval.turn) !=
                        _mapper.resourceKey(item.turn) ||
                    !_mapper.hasSameRoute(approval.resource, requested)))) {
          throw const FormatException('Conversation history route mismatch');
        }
      }

      summary ??= _mapper.conversation(response.conversation);
      activeTurn ??=
          responseActiveTurn == null ? null : _mapper.turn(responseActiveTurn);
      snapshotCursor ??= response.snapshotCursor;
      pages.add(response.items);

      final nextCursor = response.pageInfo?.nextCursor;
      if (nextCursor == null) break;
      if (!seenCursors.add(nextCursor)) {
        throw const FormatException(
          'conversation.get returned a repeated page cursor',
        );
      }
      cursor = nextCursor;
    }

    final orderedItems = pages.reversed.expand((page) => page).toList();
    return ConversationSnapshot(
      detail: ConversationDetail(
        summary: summary,
        committedMessages: [
          for (var index = 0; index < orderedItems.length; index++)
            _mapper.message(orderedItems[index], index),
        ],
        turns: [?activeTurn],
        lastEventCursor: snapshotCursor,
      ),
      snapshotCursor: snapshotCursor,
    );
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
    return ConversationInteraction(
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
  }

  @override
  Future<ConversationSummary> createConversation({
    required GatewayProviderRoute route,
    String? title,
    required String permissionLevel,
    String? model,
    String? reasoningEffort,
    String? workspaceRoot,
    String? workspaceMode,
  }) async {
    _validateProviderRequest(route, cursor: null, limit: 1);
    final provider = _providersByRoute[route.key];
    if (provider == null ||
        provider.status != ProviderStatus.ready ||
        !provider.methods.contains('conversation.create')) {
      throw const FormatException(
        'Provider conversation.create capability is unavailable',
      );
    }
    final response = await _call(
      () => _protocol.conversationCreate(
        sdk.ConversationCreateRequest(
          route: _mapper.sdkProviderRoute(route),
          title: title,
          permissionLevel: permissionLevel,
          model: model,
          reasoningEffort: reasoningEffort,
          workspaceRoot: workspaceRoot,
          workspaceMode: workspaceMode,
        ),
      ),
    );
    _mapper.requireExpectedResource(
      response.conversation.resource,
      expectedDeviceId: expectedDeviceId,
      expectedProviderRouteKeys: _providerRouteKeys,
    );
    if (response.conversation.resource.providerPluginId !=
            route.providerPluginId ||
        response.conversation.resource.providerInstanceId !=
            route.providerInstanceId) {
      throw const FormatException(
        'conversation.create returned a different Provider route',
      );
    }
    return _mapper.conversation(response.conversation);
  }

  @override
  Future<TurnSendReceipt> sendTurn({
    required GatewayProviderRoute route,
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
    _validateProviderRequest(route, cursor: null, limit: 1);
    final provider = _providersByRoute[route.key];
    if (provider == null ||
        provider.status != ProviderStatus.ready ||
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
    if (resource.deviceId != route.deviceId ||
        resource.providerPluginId != route.providerPluginId ||
        resource.providerInstanceId != route.providerInstanceId) {
      throw const FormatException(
        'Conversation route does not match turn.send Provider route',
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
            (_mapper.resourceKey(userItem.conversation) !=
                    _mapper.resourceKey(resource) ||
                _mapper.resourceKey(userItem.turn) !=
                    _mapper.resourceKey(response.turn.resource) ||
                !_mapper.hasSameRoute(userItem.resource, resource) ||
                userItem.role != sdk.ConversationItemRole.user)) ||
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
  Future<void> close() async {
    _providerRouteKeys = const {};
    _providersByRoute.clear();
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
