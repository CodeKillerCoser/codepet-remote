import 'dart:async';

import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('performs the v1 handshake, subscribe, list and get sequence', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'conversation.list': {
        'conversations': [_conversationJson()],
        'pageInfo': <String, dynamic>{},
        'snapshotCursor': 'opaque-snapshot',
      },
      'conversation.get': {
        'conversation': _conversationJson(),
        'snapshotCursor': 'opaque-snapshot',
      },
    });
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);

    final handshake = await client.connect();
    final page = await client.listConversations(limit: 25);
    final detail = await client.getConversation(page.conversations.single);

    expect(transport.connected, isTrue);
    expect(handshake.protocolVersion, gatewayProtocolVersion);
    expect(handshake.providers.single.id, 'codex-work');
    expect(transport.requests[0].method, 'protocol.handshake');
    expect(transport.requests[0].params['supportedVersions'], {'minVersion': 1, 'maxVersion': 1});
    expect(transport.requests[1].method, 'event.subscribe');
    expect(transport.requests[1].params['afterCursor'], 'opaque-handshake');
    expect(transport.requests[2].method, 'conversation.list');
    expect(transport.requests[2].params['limit'], 25);
    expect(transport.requests[3].method, 'conversation.get');
    expect(detail.summary.wireResource!['nativeResourceId'], 'conversation-1');
    expect(detail.messages, isEmpty);

    await client.close();
    expect(transport.closed, isTrue);
  });

  test('projects transport events into Gateway events', () async {
    final transport = _FakeTransport({});
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);
    final eventFuture = client.events.first;

    transport.emit({
      'protocolVersion': 1,
      'eventCursor': 'opaque-event-7',
      'event': 'conversation.upserted',
      'payload': {'conversation': _conversationJson()},
    });

    final event = await eventFuture;
    expect(event, isA<ConversationUpsertedEvent>());
    expect((event as ConversationUpsertedEvent).conversation.wireResource!['nativeResourceId'], 'conversation-1');
    await client.close();
  });
}

class _FakeTransport implements GatewayTransport {
  _FakeTransport(this.responses);

  final Map<String, JsonMap> responses;
  final StreamController<JsonMap> _events =
      StreamController<JsonMap>.broadcast();
  final List<_RequestRecord> requests = [];
  bool connected = false;
  bool closed = false;

  @override
  Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    connected = true;
  }

  @override
  Future<JsonMap> request(String method, JsonMap params) async {
    requests.add(_RequestRecord(method, params));
    final response = responses[method];
    if (response == null) {
      throw StateError('No response for $method');
    }
    return response;
  }

  void emit(JsonMap event) {
    _events.add(event);
  }

  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
  }
}

class _RequestRecord {
  const _RequestRecord(this.method, this.params);

  final String method;
  final JsonMap params;
}

JsonMap _handshakeJson() {
  return {
    'selectedVersion': 1,
    'serverName': 'CodePet Host',
    'serverVersion': '0.1.0',
    'device': {'deviceId': 'device-test', 'displayName': 'Test', 'identityFingerprint': _fingerprint},
    'devices': <Object>[],
    'providers': [
      {
        'route': {'deviceId': 'device-test', 'providerPluginId': 'dev.codepet.codex', 'providerInstanceId': 'codex-work'},
        'pluginId': 'dev.codepet.codex',
        'displayName': 'Codex',
        'status': 'ready',
        'capabilities': {
          'methods': ['conversation.list', 'conversation.get'],
          'permissionLevels': ['read-only'],
          'models': <String>[],
          'reasoningEfforts': <String>[],
          'quickReplies': <Object>[],
          'canSteer': false,
          'canInterrupt': false,
        },
      },
    ],
    'eventCursor': 'opaque-handshake',
  };
}

JsonMap _conversationJson() {
  return {
    'resource': {'deviceId': 'device-test', 'providerPluginId': 'dev.codepet.codex', 'providerInstanceId': 'codex-work', 'nativeResourceId': 'conversation-1'},
    'title': 'Test conversation',
    'status': 'idle',
    'permissionLevel': 'read-only',
    'createdAt': 1000,
    'updatedAt': 2000,
  };
}

const _fingerprint = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
