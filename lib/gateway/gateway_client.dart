import 'dart:async';
import 'dart:collection';

import '../discovery/resolving_gateway_transport.dart';
import 'models.dart';
import 'transport.dart';
import 'v1_models.dart';

abstract interface class GatewayClient {
  Stream<GatewayEvent> get events;
  String? get latestEventCursor;
  GatewayEventWindow openEventWindow();
  Future<GatewayHandshake> connect();
  Future<ConversationPage> listConversations({required GatewayProviderRoute route, String? cursor, int limit = 50});
  Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50});
  Future<ConversationSnapshot> getConversation(ConversationSummary conversation);
  Future<void> close();
}

class ConversationSnapshot {
  const ConversationSnapshot({required this.detail, required this.snapshotCursor});
  final ConversationDetail detail;
  final String snapshotCursor;
}

class GatewayCursorGapException implements Exception {
  const GatewayCursorGapException(this.message);
  final String message;
  @override
  String toString() => message;
}

class GatewayEventWindow {
  GatewayEventWindow._(this.startCursor, Stream<GatewayEvent> events) {
    _subscription = events.listen((event) {
      if (_onEvent == null) {
        _buffer.add(event);
      } else {
        _deliver(event);
      }
    }, onError: (Object error, StackTrace stack) {
      if (_onEvent == null) {
        _errors.add((error, stack));
      } else {
        _onError?.call(error, stack);
      }
    });
  }

  factory GatewayEventWindow.forStream(
    String? startCursor,
    Stream<GatewayEvent> events,
  ) => GatewayEventWindow._(startCursor, events);

  final String? startCursor;
  final List<GatewayEvent> _buffer = [];
  final List<(Object, StackTrace)> _errors = [];
  final _BoundedCursorSet _delivered = _BoundedCursorSet();
  late final StreamSubscription<GatewayEvent> _subscription;
  void Function(GatewayEvent)? _onEvent;
  void Function(Object, StackTrace)? _onError;

  void install({required String baselineCursor, required String snapshotCursor, required void Function(GatewayEvent) onEvent, void Function(Object, StackTrace)? onError}) {
    if (_onEvent != null) throw StateError('Gateway event window is already installed');
    if (_errors.isNotEmpty) {
      Error.throwWithStackTrace(_errors.first.$1, _errors.first.$2);
    }
    var boundary = -1;
    for (var index = 0; index < _buffer.length; index++) {
      if (_buffer[index].eventCursor == snapshotCursor) boundary = index;
    }
    if (snapshotCursor != baselineCursor && boundary == -1) {
      throw const GatewayCursorGapException('Snapshot cursor was not found in the subscribed event window');
    }
    _onEvent = onEvent;
    _onError = onError;
    final suffix = _buffer.skip(boundary + 1).toList(growable: false);
    _buffer.clear();
    for (final event in suffix) {
      _deliver(event);
    }
  }

  void _deliver(GatewayEvent event) {
    if (_delivered.add(event.eventCursor)) _onEvent?.call(event);
  }

  Future<void> close() => _subscription.cancel();
}

class ProtocolGatewayClient implements GatewayClient {
  ProtocolGatewayClient({required this.transport, required this.clientId, required this.clientDevice, required this.expectedDeviceId, required this.expectedIdentityFingerprint, this.clientVersion = '0.1.0', this.onValidatedEndpoint, this.onValidatedHostDescriptor});
  final GatewayTransport transport;
  final String clientId;
  final DeviceDescriptor clientDevice;
  final String expectedDeviceId;
  final String expectedIdentityFingerprint;
  final String clientVersion;
  final FutureOr<void> Function(Uri endpoint)? onValidatedEndpoint;
  final FutureOr<void> Function(DeviceDescriptor descriptor)? onValidatedHostDescriptor;
  final StreamController<GatewayEvent> _events = StreamController<GatewayEvent>.broadcast(sync: true);
  StreamSubscription<JsonMap>? _transportEvents;
  String? _latestEventCursor;
  final _BoundedCursorSet _seenEventCursors = _BoundedCursorSet();
  Set<String> _providerRouteKeys = const {};

  @override Stream<GatewayEvent> get events => _events.stream;
  @override String? get latestEventCursor => _latestEventCursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow._(_latestEventCursor, events);

  @override
  Future<GatewayHandshake> connect() async {
    _transportEvents ??= transport.events.listen((raw) {
      try {
        final event = _eventFromV1(raw, expectedDeviceId: expectedDeviceId);
        if (!_seenEventCursors.add(event.eventCursor)) return;
        _latestEventCursor = event.eventCursor;
        _events.add(event);
      } catch (error, stack) {
        final protocolError = error is FormatException
            ? error
            : FormatException('Invalid Gateway v1 event: $error');
        _events.addError(protocolError, stack);
      }
    }, onError: _events.addError);
    await transport.connect();
    final raw = await transport.request('protocol.handshake', {
      'clientId': clientId, 'device': clientDevice.toJson(), 'clientVersion': clientVersion,
      'supportedVersions': {'minVersion': 1, 'maxVersion': 1},
    });
    final handshake = V1Handshake.fromJson(raw);
    if (handshake.selectedVersion != 1 || handshake.device.deviceId != expectedDeviceId || handshake.device.identityFingerprint != expectedIdentityFingerprint) {
      await transport.close();
      throw const GatewayConnectionException(
        'Gateway identity mismatch',
        retryable: false,
      );
    }
    await onValidatedHostDescriptor?.call(handshake.device.descriptor);
    _seenEventCursors.add(handshake.eventCursor);
    final subscription = await transport.request('event.subscribe', {'afterCursor': handshake.eventCursor});
    if (subscription['subscribedAfterCursor'] != handshake.eventCursor) {
      await transport.close();
      throw const GatewayConnectionException(
        'Gateway subscription cursor mismatch',
        retryable: false,
      );
    }
    _latestEventCursor ??= handshake.eventCursor;
    final endpoint = transport is EndpointAwareGatewayTransport
        ? (transport as EndpointAwareGatewayTransport).selectedGatewayUri
        : null;
    if (endpoint != null) await onValidatedEndpoint?.call(endpoint);
    final providers = handshake.providers.map((json) {
      final provider = GatewayProvider.fromJson(json);
      if (provider.route.deviceId != expectedDeviceId) {
        throw const FormatException(
          'Provider route does not belong to the connected Host',
        );
      }
      return provider;
    }).toList(growable: false);
    _providerRouteKeys = providers.map((provider) => provider.route.key).toSet();
    return GatewayHandshake(protocolVersion: 1, serverName: handshake.serverName, serverVersion: handshake.serverVersion, providers: providers, eventCursor: handshake.eventCursor, deviceId: handshake.device.deviceId, identityFingerprint: handshake.device.identityFingerprint, deviceDescriptor: handshake.device.descriptor);
  }

  @override
  Future<ConversationPage> listConversations({required GatewayProviderRoute route, String? cursor, int limit = 50}) async {
    _validateProviderRequest(route, cursor: cursor, limit: limit);
    final result = await transport.request('conversation.list', {
      'route': route.toJson(),
      'cursor': ?cursor,
      'limit': limit,
    });
    return _conversationPageFromResult(
      result,
      method: 'conversation.list',
      route: route,
    );
  }

  @override
  Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) async {
    if (searchTerm.trim().isEmpty) {
      throw ArgumentError.value(searchTerm, 'searchTerm', 'must not be empty');
    }
    _validateProviderRequest(route, cursor: cursor, limit: limit);
    final result = await transport.request('conversation.search', {
      'route': route.toJson(),
      'searchTerm': searchTerm,
      'cursor': ?cursor,
      'limit': limit,
    });
    return _conversationPageFromResult(
      result,
      method: 'conversation.search',
      route: route,
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

  ConversationPage _conversationPageFromResult(
    JsonMap result, {
    required String method,
    required GatewayProviderRoute route,
  }) {
    const resultFields = {'conversations', 'pageInfo', 'snapshotCursor'};
    if (result.keys.toSet().difference(resultFields).isNotEmpty ||
        resultFields.difference(result.keys.toSet()).isNotEmpty) {
      throw FormatException('Invalid $method result fields');
    }
    final raw = result['conversations'];
    final pageInfo = result['pageInfo'];
    final snapshotCursor = result['snapshotCursor'];
    if (raw is! List ||
        pageInfo is! Map ||
        snapshotCursor is! String ||
        snapshotCursor.isEmpty) {
      throw FormatException('Invalid $method result');
    }
    final typedPageInfo = Map<String, dynamic>.from(pageInfo);
    if (typedPageInfo.keys.any((key) => key != 'nextCursor')) {
      throw FormatException('Invalid $method pageInfo fields');
    }
    final conversations = raw.map((item) {
      if (item is! Map) throw FormatException('Invalid $method conversation');
      final conversation = V1Conversation.fromJson(
        Map<String, dynamic>.from(item),
      );
      if (conversation.resource.deviceId != route.deviceId ||
          conversation.resource.providerPluginId != route.providerPluginId ||
          conversation.resource.providerInstanceId != route.providerInstanceId) {
        throw FormatException('$method returned a different Provider route');
      }
      return conversation.toDomain();
    }).toList(growable: false);
    final nextCursor = typedPageInfo['nextCursor'];
    if (nextCursor != null && (nextCursor is! String || nextCursor.isEmpty)) {
      throw FormatException('Invalid $method next cursor');
    }
    return ConversationPage(
      conversations: conversations,
      nextCursor: nextCursor as String?,
      snapshotCursor: snapshotCursor,
    );
  }

  @override
  Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async {
    final resource = conversation.wireResource;
    if (resource == null) throw const FormatException('Conversation has no v1 routed identity');
    final result = await transport.request('conversation.get', {'conversation': resource});
    final raw = result['conversation'];
    final rawItems = result['items'];
    final cursor = result['snapshotCursor'];
    if (raw is! Map || rawItems is! List || cursor is! String) throw const FormatException('Invalid conversation.get result');
    final wireConversation = V1Conversation.fromJson(Map<String, dynamic>.from(raw));
    final requested = RoutedResourceId.fromJson(resource);
    if (wireConversation.resource.key != requested.key || wireConversation.resource.deviceId != expectedDeviceId) {
      throw const FormatException('conversation.get returned a different routed conversation');
    }
    final items = <V1ConversationItem>[];
    for (final rawItem in rawItems) {
      if (rawItem is! Map) throw const FormatException('Invalid conversation history item');
      final item = V1ConversationItem.fromJson(Map<String, dynamic>.from(rawItem));
      if (item.conversation.key != requested.key ||
          !item.resource.hasRouteOf(requested) ||
          !item.turn.hasRouteOf(requested) ||
          (item.relatedItem != null &&
              !item.relatedItem!.hasRouteOf(requested)) ||
          (item.approval != null &&
              (item.approval!.conversation.key != requested.key ||
                  item.approval!.turn.key != item.turn.key ||
                  !item.approval!.resource.hasRouteOf(requested)))) {
        throw const FormatException('Conversation history route mismatch');
      }
      items.add(item);
    }
    return ConversationSnapshot(
      detail: ConversationDetail(
        summary: wireConversation.toDomain(),
        committedMessages: [
          for (var index = 0; index < items.length; index++)
            items[index].toDomain(index),
        ],
        lastEventCursor: cursor,
      ),
      snapshotCursor: cursor,
    );
  }

  @override
  Future<void> close() async {
    _providerRouteKeys = const {};
    await _transportEvents?.cancel();
    _transportEvents = null;
    await transport.close();
    await _events.close();
  }
}

GatewayEvent _eventFromV1(JsonMap json, {required String expectedDeviceId}) {
  final cursor = json['eventCursor'];
  final event = json['event'];
  final payload = json['payload'];
  if (cursor is! String || cursor.isEmpty || event is! String || payload is! Map) throw const FormatException('Invalid Gateway v1 event envelope');
  final data = Map<String, dynamic>.from(payload);
  if (event == 'conversation.upserted' && data['conversation'] is Map) {
    final conversation = V1Conversation.fromJson(Map<String, dynamic>.from(data['conversation'] as Map));
    if (conversation.resource.deviceId != expectedDeviceId) throw const FormatException('Conversation event route does not belong to the connected Host');
    return ConversationUpsertedEvent(eventCursor: cursor, conversation: conversation.toDomain());
  }
  if (event == 'turn.upserted' && data['turn'] is Map) {
    final turn = Map<String, dynamic>.from(data['turn'] as Map);
    final resource = RoutedResourceId.fromJson(Map<String, dynamic>.from(turn['resource'] as Map));
    final conversation = RoutedResourceId.fromJson(Map<String, dynamic>.from(turn['conversation'] as Map));
    if (resource.deviceId != expectedDeviceId || conversation.deviceId != expectedDeviceId || !resource.hasRouteOf(conversation)) throw const FormatException('Invalid turn route');
    return TurnUpsertedEvent(eventCursor: cursor, turn: TurnTask(id: resource.key, providerId: resource.providerInstanceId, conversationId: conversation.key, status: TurnStatus.fromWire(turn['status']), displaySummary: turn['displaySummary'] as String?, startedAt: _optionalV1Time(turn['startedAt']), updatedAt: _optionalV1Time(turn['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true), completedAt: _optionalV1Time(turn['completedAt']), wireResource: resource.toJson(), conversationWireResource: conversation.toJson()));
  }
  if (event == 'turn.outputDelta') {
    final turn = RoutedResourceId.fromJson(Map<String, dynamic>.from(data['turn'] as Map));
    final conversation = RoutedResourceId.fromJson(Map<String, dynamic>.from(data['conversation'] as Map));
    if (turn.deviceId != expectedDeviceId || conversation.deviceId != expectedDeviceId || !turn.hasRouteOf(conversation)) throw const FormatException('Invalid output delta route');
    final itemId = data['itemId'];
    final contentId = data['contentId'];
    final kind = data['kind'];
    final delta = data['delta'];
    const contentKinds = {'text', 'reasoning-summary', 'command', 'output', 'activity-summary'};
    if (itemId is! String || itemId.isEmpty || contentId is! String || contentId.isEmpty || kind is! String || !contentKinds.contains(kind) || delta is! String) throw const FormatException('Invalid turn.outputDelta payload');
    return TurnOutputDeltaEvent(eventCursor: cursor, providerId: turn.providerInstanceId, conversationId: conversation.key, turnId: turn.key, itemId: itemId, contentId: contentId, kind: kind, delta: delta);
  }
  return UnknownGatewayEvent(eventCursor: cursor, name: event, payload: data);
}

DateTime? _optionalV1Time(Object? value) {
  if (value == null) return null;
  if (value is! int) throw const FormatException('Invalid Gateway timestamp');
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
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
