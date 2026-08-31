import 'models.dart';
import 'transport.dart';
import 'v1_models.dart';

abstract interface class GatewayClient {
  Stream<GatewayEvent> get events;
  Future<GatewayHandshake> connect();
  Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50});
  Future<ConversationDetail> getConversation(ConversationSummary conversation);
  Future<void> close();
}

class ProtocolGatewayClient implements GatewayClient {
  ProtocolGatewayClient({required this.transport, required this.clientId, required this.expectedDeviceId, required this.expectedIdentityFingerprint, this.clientName = 'CodePet Remote', this.clientVersion = '0.1.0'});
  final GatewayTransport transport;
  final String clientId;
  final String expectedDeviceId;
  final String expectedIdentityFingerprint;
  final String clientName;
  final String clientVersion;

  @override Stream<GatewayEvent> get events => transport.events.map(_eventFromV1);

  @override
  Future<GatewayHandshake> connect() async {
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
    final subscription = await transport.request('event.subscribe', {'afterCursor': handshake.eventCursor});
    if (subscription['subscribedAfterCursor'] != handshake.eventCursor) {
      await transport.close();
      throw const GatewayConnectionException('Gateway subscription cursor mismatch');
    }
    final providers = handshake.providers.map((json) {
      final route = Map<String, dynamic>.from(json['route'] as Map);
      final capabilities = Map<String, dynamic>.from(json['capabilities'] as Map);
      return GatewayProvider(id: route['providerInstanceId'] as String, providerType: json['pluginId'] as String, displayName: json['displayName'] as String, status: ProviderStatus.fromWire(json['status']), methods: (capabilities['methods'] as List).cast<String>());
    }).toList(growable: false);
    return GatewayHandshake(protocolVersion: 1, serverName: handshake.serverName, serverVersion: handshake.serverVersion, providers: providers, eventSequence: 0, eventCursor: handshake.eventCursor, deviceId: handshake.device.deviceId, identityFingerprint: handshake.device.identityFingerprint);
  }

  @override
  Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) async {
    final result = await transport.request('conversation.list', {'cursor': ?cursor, 'limit': limit});
    final raw = result['conversations'];
    final pageInfo = result['pageInfo'];
    if (raw is! List || pageInfo is! Map || result['snapshotCursor'] is! String) throw const FormatException('Invalid conversation.list result');
    return ConversationPage(
      conversations: raw.map((item) => V1Conversation.fromJson(Map<String, dynamic>.from(item as Map)).toDomain()).toList(growable: false),
      nextCursor: pageInfo['nextCursor'] as String?, eventSequence: 0, snapshotCursor: result['snapshotCursor'] as String,
    );
  }

  @override
  Future<ConversationDetail> getConversation(ConversationSummary conversation) async {
    final resource = conversation.wireResource;
    if (resource == null) throw const FormatException('Conversation has no v1 routed identity');
    final result = await transport.request('conversation.get', {'conversation': resource});
    final raw = result['conversation'];
    if (raw is! Map || result['snapshotCursor'] is! String) throw const FormatException('Invalid conversation.get result');
    return ConversationDetail(summary: V1Conversation.fromJson(Map<String, dynamic>.from(raw)).toDomain());
  }

  @override Future<void> close() => transport.close();
}

GatewayEvent _eventFromV1(JsonMap json) {
  final cursor = json['eventCursor'];
  final event = json['event'];
  final payload = json['payload'];
  if (cursor is! String || cursor.isEmpty || event is! String || payload is! Map) throw const FormatException('Invalid Gateway v1 event envelope');
  final data = Map<String, dynamic>.from(payload);
  if (event == 'conversation.upserted' && data['conversation'] is Map) {
    return ConversationUpsertedEvent(sequence: 0, conversation: V1Conversation.fromJson(Map<String, dynamic>.from(data['conversation'] as Map)).toDomain());
  }
  return UnknownGatewayEvent(sequence: 0, name: event, payload: data);
}
