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
  Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50});
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
  ProtocolGatewayClient({required this.transport, required this.clientId, required this.expectedDeviceId, required this.expectedIdentityFingerprint, this.clientName = 'CodePet Remote', this.clientVersion = '0.1.0', this.onValidatedEndpoint});
  final GatewayTransport transport;
  final String clientId;
  final String expectedDeviceId;
  final String expectedIdentityFingerprint;
  final String clientName;
  final String clientVersion;
  final FutureOr<void> Function(Uri endpoint)? onValidatedEndpoint;
  final StreamController<GatewayEvent> _events = StreamController<GatewayEvent>.broadcast(sync: true);
  StreamSubscription<JsonMap>? _transportEvents;
  String? _latestEventCursor;
  final _BoundedCursorSet _seenEventCursors = _BoundedCursorSet();

  @override Stream<GatewayEvent> get events => _events.stream;
  @override String? get latestEventCursor => _latestEventCursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow._(_latestEventCursor, events);

  @override
  Future<GatewayHandshake> connect() async {
    _transportEvents ??= transport.events.listen((raw) {
      try {
        final event = _eventFromV1(raw);
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
      'clientId': clientId, 'clientName': clientName, 'clientVersion': clientVersion,
      'supportedVersions': {'minVersion': 1, 'maxVersion': 1},
    });
    final handshake = V1Handshake.fromJson(raw);
    if (handshake.selectedVersion != 1 || handshake.device.deviceId != expectedDeviceId || handshake.device.identityFingerprint != expectedIdentityFingerprint) {
      await transport.close();
      throw const GatewayConnectionException('Gateway identity mismatch');
    }
    _seenEventCursors.add(handshake.eventCursor);
    final subscription = await transport.request('event.subscribe', {'afterCursor': handshake.eventCursor});
    if (subscription['subscribedAfterCursor'] != handshake.eventCursor) {
      await transport.close();
      throw const GatewayConnectionException('Gateway subscription cursor mismatch');
    }
    _latestEventCursor ??= handshake.eventCursor;
    final endpoint = transport is EndpointAwareGatewayTransport
        ? (transport as EndpointAwareGatewayTransport).selectedGatewayUri
        : null;
    if (endpoint != null) await onValidatedEndpoint?.call(endpoint);
    final providers = handshake.providers.map((json) {
      final route = Map<String, dynamic>.from(json['route'] as Map);
      final capabilities = Map<String, dynamic>.from(json['capabilities'] as Map);
      return GatewayProvider(id: route['providerInstanceId'] as String, providerType: json['pluginId'] as String, displayName: json['displayName'] as String, status: ProviderStatus.fromWire(json['status']), methods: (capabilities['methods'] as List).cast<String>());
    }).toList(growable: false);
    return GatewayHandshake(protocolVersion: 1, serverName: handshake.serverName, serverVersion: handshake.serverVersion, providers: providers, eventCursor: handshake.eventCursor, deviceId: handshake.device.deviceId, identityFingerprint: handshake.device.identityFingerprint);
  }

  @override
  Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) async {
    final result = await transport.request('conversation.list', {'cursor': ?cursor, 'limit': limit});
    final raw = result['conversations'];
    final pageInfo = result['pageInfo'];
    if (raw is! List || pageInfo is! Map || result['snapshotCursor'] is! String) throw const FormatException('Invalid conversation.list result');
    return ConversationPage(conversations: raw.map((item) => V1Conversation.fromJson(Map<String, dynamic>.from(item as Map)).toDomain()).toList(growable: false), nextCursor: pageInfo['nextCursor'] as String?, snapshotCursor: result['snapshotCursor'] as String);
  }

  @override
  Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async {
    final resource = conversation.wireResource;
    if (resource == null) throw const FormatException('Conversation has no v1 routed identity');
    final result = await transport.request('conversation.get', {'conversation': resource});
    final raw = result['conversation'];
    final cursor = result['snapshotCursor'];
    if (raw is! Map || cursor is! String) throw const FormatException('Invalid conversation.get result');
    return ConversationSnapshot(detail: ConversationDetail(summary: V1Conversation.fromJson(Map<String, dynamic>.from(raw)).toDomain()), snapshotCursor: cursor);
  }

  @override
  Future<void> close() async {
    await _transportEvents?.cancel();
    _transportEvents = null;
    await transport.close();
    await _events.close();
  }
}

GatewayEvent _eventFromV1(JsonMap json) {
  final cursor = json['eventCursor'];
  final event = json['event'];
  final payload = json['payload'];
  if (cursor is! String || cursor.isEmpty || event is! String || payload is! Map) throw const FormatException('Invalid Gateway v1 event envelope');
  final data = Map<String, dynamic>.from(payload);
  if (event == 'conversation.upserted' && data['conversation'] is Map) {
    return ConversationUpsertedEvent(eventCursor: cursor, conversation: V1Conversation.fromJson(Map<String, dynamic>.from(data['conversation'] as Map)).toDomain());
  }
  if (event == 'turn.upserted' && data['turn'] is Map) {
    final turn = Map<String, dynamic>.from(data['turn'] as Map);
    final resource = RoutedResourceId.fromJson(Map<String, dynamic>.from(turn['resource'] as Map));
    final conversation = RoutedResourceId.fromJson(Map<String, dynamic>.from(turn['conversation'] as Map));
    return TurnUpsertedEvent(eventCursor: cursor, turn: TurnTask(id: resource.key, providerId: resource.providerInstanceId, conversationId: conversation.key, status: TurnStatus.fromWire(turn['status']), displaySummary: turn['displaySummary'] as String?, startedAt: _optionalV1Time(turn['startedAt']), updatedAt: _optionalV1Time(turn['updatedAt']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true), completedAt: _optionalV1Time(turn['completedAt']), wireResource: resource.toJson(), conversationWireResource: conversation.toJson()));
  }
  if (event == 'turn.outputDelta') {
    final turn = RoutedResourceId.fromJson(Map<String, dynamic>.from(data['turn'] as Map));
    final conversation = RoutedResourceId.fromJson(Map<String, dynamic>.from(data['conversation'] as Map));
    final outputId = data['outputId'];
    final kind = data['kind'];
    final delta = data['delta'];
    if (outputId is! String || outputId.isEmpty || kind is! String || kind.isEmpty || delta is! String) throw const FormatException('Invalid turn.outputDelta payload');
    return TurnOutputDeltaEvent(eventCursor: cursor, providerId: turn.providerInstanceId, conversationId: conversation.key, turnId: turn.key, outputId: outputId, kind: kind, delta: delta);
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
