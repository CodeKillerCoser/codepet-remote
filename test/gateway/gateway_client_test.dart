import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:codepet_remote/gateway/v1_models.dart';
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
        'items': <Object>[],
        'snapshotCursor': 'opaque-snapshot',
      },
    });
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', clientDevice: _clientDevice, expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);

    final handshake = await client.connect();
    final page = await client.listConversations(
      route: handshake.providers.single.route,
      limit: 25,
    );
    final detail = await client.getConversation(page.conversations.single);

    expect(transport.connected, isTrue);
    expect(handshake.protocolVersion, gatewayProtocolVersion);
    expect(handshake.providers.single.id, 'codex-work');
    expect(handshake.providers.single.route, _route);
    expect(transport.requests[0].method, 'protocol.handshake');
    expect(transport.requests[0].params['device'], _clientDevice.toJson());
    expect(transport.requests[0].params, isNot(contains('clientName')));
    expect(transport.requests[0].params['supportedVersions'], {'minVersion': 1, 'maxVersion': 1});
    expect(transport.requests[1].method, 'event.subscribe');
    expect(transport.requests[1].params['afterCursor'], 'opaque-handshake');
    expect(transport.requests[2].method, 'conversation.list');
    expect(transport.requests[2].params['route'], _route.toJson());
    expect(transport.requests[2].params['limit'], 25);
    expect(transport.requests[3].method, 'conversation.get');
    expect(detail.detail.summary.wireResource!['nativeResourceId'], 'conversation-1');
    expect(detail.detail.messages, isEmpty);

    await client.close();
    expect(transport.closed, isTrue);
  });

  test('sends original text with route, revision and flat selection', () async {
    final handshakeJson = _handshakeJson();
    final provider = (handshakeJson['providers'] as List).single
        as Map<String, dynamic>;
    final capabilities = provider['capabilities'] as Map<String, dynamic>;
    capabilities['turnSend'] = {
      'modelCatalog': {
        'kind': 'flat',
        'models': [
          {'id': 'model-a', 'displayName': 'Model A'},
        ],
        'defaultSelection': {'kind': 'flat', 'modelId': 'model-a'},
      },
    };
    final transport = _FakeTransport({
      'protocol.handshake': handshakeJson,
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'turn.send': _turnSendResult(
        selection: {'model': {'kind': 'flat', 'modelId': 'model-a'}},
      ),
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();
    final conversation = V1Conversation.fromJson(_conversationJson()).toDomain();
    const selection = TurnSendSelection(
      model: FlatModelSelection(modelId: 'model-a'),
    );

    final receipt = await client.sendTurn(
      route: _route,
      conversation: conversation,
      clientRequestId: 'request-1',
      capabilityRevision: 'revision-1',
      text: '  keep whitespace\n',
      selection: selection,
    );

    expect(transport.requests.last.method, 'turn.send');
    expect(transport.requests.last.params, {
      'route': _route.toJson(),
      'conversation': conversation.wireResource,
      'clientRequestId': 'request-1',
      'capabilityRevision': 'revision-1',
      'input': {'kind': 'text', 'text': '  keep whitespace\n'},
      'selection': {
        'model': {'kind': 'flat', 'modelId': 'model-a'},
      },
    });
    expect(receipt.clientRequestId, 'request-1');
    expect(receipt.inputItem.content, '  keep whitespace\n');
    expect(receipt.turn.conversationId, conversation.id);
    await client.close();
  });

  test('preserves grouped model identity and rejects a mismatched receipt', () async {
    final handshakeJson = _handshakeJson();
    final provider = (handshakeJson['providers'] as List).single
        as Map<String, dynamic>;
    final capabilities = provider['capabilities'] as Map<String, dynamic>;
    capabilities['turnSend'] = {
      'modelCatalog': {
        'kind': 'grouped',
        'providers': [
          {
            'id': 'inference',
            'displayName': 'Inference',
            'models': [
              {'id': 'model-a', 'displayName': 'Model A'},
            ],
          },
        ],
      },
    };
    final result = _turnSendResult(selection: {
      'model': {
        'kind': 'grouped',
        'providerId': 'inference',
        'modelId': 'model-a',
      },
    });
    final userItem = result['userItem'] as Map<String, dynamic>;
    userItem['conversation'] = {
      ..._route.toJson(),
      'nativeResourceId': 'another-conversation',
    };
    final transport = _FakeTransport({
      'protocol.handshake': handshakeJson,
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'turn.send': result,
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();
    final conversation = V1Conversation.fromJson(_conversationJson()).toDomain();

    await expectLater(
      client.sendTurn(
        route: _route,
        conversation: conversation,
        clientRequestId: 'request-grouped',
        capabilityRevision: 'revision-1',
        text: 'hello',
        selection: const TurnSendSelection(
          model: GroupedModelSelection(
            providerId: 'inference',
            modelId: 'model-a',
          ),
        ),
      ),
      throwsFormatException,
    );
    expect(
      transport.requests.last.params['selection'],
      {
        'model': {
          'kind': 'grouped',
          'providerId': 'inference',
          'modelId': 'model-a',
        },
      },
    );
    await client.close();
  });

  test('decodes the Host committed history fixture in wire order', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _fixtureResult('handshake-response.json'),
      'event.subscribe': {'subscribedAfterCursor': 'event-40'},
      'conversation.list': _fixtureResult('conversation-list-response.json'),
      'conversation.get': _fixtureResult('conversation-get-response.json'),
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'remote-client-phone-1',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-macbook-1',
      expectedIdentityFingerprint: _fingerprint,
    );

    final handshake = await client.connect();
    final page = await client.listConversations(
      route: handshake.providers.single.route,
    );
    final snapshot = await client.getConversation(page.conversations.single);
    final history = snapshot.detail.committedMessages;

    expect(handshake.deviceDescriptor?.deviceName, 'MacBook');
    expect(handshake.deviceDescriptor?.operatingSystem, 'macOS');
    expect(history, hasLength(5));
    expect(history[0].role, MessageRole.user);
    expect(history[0].content, 'Show the Gateway history.');
    expect(history[1].kind, 'reasoning');
    expect(history[1].content, 'Inspecting the stored thread items.');
    expect(history[2].kind, 'command');
    expect(history[2].title, 'Run git status --short');
    expect(history[3].kind, 'approval');
    expect(history[3].approvalStatus, 'approved');
    expect(history[4].role, MessageRole.assistant);
    expect(history[4].content, 'The committed history is ready.');
    expect(history[4].contentIds, ['message-agent-01:text']);
    await client.close();
  });

  test('maps conversation selection and active turn from the routed snapshot', () async {
    final handshakeJson = _handshakeJson();
    final provider = (handshakeJson['providers'] as List).single
        as Map<String, dynamic>;
    final capabilities = provider['capabilities'] as Map<String, dynamic>;
    capabilities['turnSend'] = {
      'modelCatalog': {
        'kind': 'flat',
        'models': [
          {'id': 'model-a', 'displayName': 'Model A'},
        ],
      },
    };
    final conversation = _conversationJson();
    conversation['selection'] = {
      'model': {'kind': 'flat', 'modelId': 'model-a'},
    };
    conversation['activeTurn'] = {
      'resource': {
        ..._route.toJson(),
        'nativeResourceId': 'active-turn',
      },
      'conversation': conversation['resource'],
      'status': 'running',
      'updatedAt': 2500,
    };
    conversation['status'] = 'running';
    final transport = _FakeTransport({
      'protocol.handshake': handshakeJson,
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'conversation.get': {
        'conversation': conversation,
        'items': <Object>[],
        'snapshotCursor': 'opaque-handshake',
      },
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();
    final requested = V1Conversation.fromJson(_conversationJson()).toDomain();

    final snapshot = await client.getConversation(requested);

    expect(snapshot.detail.turns, hasLength(1));
    expect(snapshot.detail.activeTurn?.status, TurnStatus.running);
    expect(snapshot.detail.summary.turnSendSelection?.model?.toJson(), {
      'kind': 'flat',
      'modelId': 'model-a',
    });
    await client.close();
  });

  test('rejects the pre-history conversation.get shape without items', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'conversation.list': {
        'conversations': [_conversationJson()],
        'pageInfo': <String, dynamic>{},
        'snapshotCursor': 'opaque-handshake',
      },
      'conversation.get': {
        'conversation': _conversationJson(),
        'snapshotCursor': 'opaque-handshake',
      },
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    final handshake = await client.connect();
    final page = await client.listConversations(
      route: handshake.providers.single.route,
    );

    expect(
      () => client.getConversation(page.conversations.single),
      throwsFormatException,
    );
    await client.close();
  });

  test('sends route-scoped search pagination and validates its route', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'conversation.search': {
        'conversations': [_conversationJson()],
        'pageInfo': {'nextCursor': 'search-next'},
        'snapshotCursor': 'opaque-search',
      },
      'conversation.get': {
        'conversation': _conversationJson(),
        'items': <Object>[],
        'snapshotCursor': 'opaque-search',
      },
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    final handshake = await client.connect();

    final page = await client.searchConversations(
      route: handshake.providers.single.route,
      searchTerm: 'gateway protocol',
      cursor: 'search-cursor',
      limit: 20,
    );

    expect(page.conversations, hasLength(1));
    expect(page.nextCursor, 'search-next');
    expect(transport.requests.last.method, 'conversation.search');
    expect(transport.requests.last.params, {
      'route': _route.toJson(),
      'searchTerm': 'gateway protocol',
      'cursor': 'search-cursor',
      'limit': 20,
    });

    await client.getConversation(page.conversations.single);
    expect(transport.requests.last.method, 'conversation.get');
    expect(
      transport.requests.last.params['conversation'],
      page.conversations.single.wireResource,
    );

    transport.responses['conversation.search'] = {
      'conversations': [
        _conversationJson()
          ..['resource'] = {
            'deviceId': 'device-test',
            'providerPluginId': 'dev.codepet.other',
            'providerInstanceId': 'other',
            'nativeResourceId': 'conversation-1',
          },
      ],
      'pageInfo': <String, dynamic>{},
      'snapshotCursor': 'opaque-search',
    };
    await expectLater(
      client.searchConversations(
        route: handshake.providers.single.route,
        searchTerm: 'gateway protocol',
      ),
      throwsFormatException,
    );
    await client.close();
  });

  test('rejects a mismatched Provider route in the handshake', () async {
    final handshake = _handshakeJson();
    final providers = handshake['providers'] as List;
    final provider = Map<String, dynamic>.from(providers.single as Map);
    provider['route'] = {
      'deviceId': 'another-device',
      'providerPluginId': 'dev.codepet.codex',
      'providerInstanceId': 'codex-work',
    };
    handshake['providers'] = [provider];
    final client = ProtocolGatewayClient(
      transport: _FakeTransport({
        'protocol.handshake': handshake,
        'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      }),
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );

    await expectLater(client.connect(), throwsFormatException);
    await client.close();
  });

  test('does not accept or refresh descriptor for a mismatched Host identity', () async {
    final handshake = _handshakeJson();
    final device = Map<String, dynamic>.from(handshake['device'] as Map);
    handshake['device'] = {
      ...device,
      'identityFingerprint': 'f' * 64,
    };
    final transport = _FakeTransport({
      'protocol.handshake': handshake,
    });
    var descriptorRefreshes = 0;
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
      onValidatedHostDescriptor: (_) {
        descriptorRefreshes++;
      },
    );

    await expectLater(
      client.connect(),
      throwsA(
        isA<GatewayConnectionException>().having(
          (error) => error.retryable,
          'retryable',
          isFalse,
        ),
      ),
    );
    expect(descriptorRefreshes, 0);
    expect(transport.closed, isTrue);
    await client.close();
  });

  test('projects transport events into Gateway events', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', clientDevice: _clientDevice, expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);
    await client.connect();
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

  test('rejects same-device unadvertised Provider replay through event window', () async {
    late _FakeTransport transport;
    transport = _FakeTransport(
      {
        'protocol.handshake': _handshakeJson(),
        'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      },
      beforeResponse: (method) {
        if (method != 'event.subscribe') return;
        final conversation = _conversationJson();
        conversation['resource'] = {
          'deviceId': 'device-test',
          'providerPluginId': 'dev.codepet.other',
          'providerInstanceId': 'other-work',
          'nativeResourceId': 'conversation-foreign',
        };
        transport.emit({
          'protocolVersion': 1,
          'eventCursor': 'opaque-foreign-provider',
          'event': 'conversation.upserted',
          'payload': {'conversation': conversation},
        });
      },
    );
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    final window = client.openEventWindow();
    final handshake = await client.connect();
    final applied = <GatewayEvent>[];

    expect(
      () => window.install(
        baselineCursor: handshake.eventCursor,
        snapshotCursor: handshake.eventCursor,
        onEvent: applied.add,
      ),
      throwsFormatException,
    );
    expect(applied, isEmpty);
    await window.close();
    await client.close();
  });

  test('projects routed turn and output delta events', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', clientDevice: _clientDevice, expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);
    final received = <GatewayEvent>[];
    final subscription = client.events.listen(received.add);
    await client.connect();
    transport.emit(_turnEvent('turn.upserted', 'cursor-turn'));
    transport.emit(_turnEvent('turn.outputDelta', 'cursor-delta'));
    await Future<void>.delayed(Duration.zero);

    final turn = received[0] as TurnUpsertedEvent;
    final delta = received[1] as TurnOutputDeltaEvent;
    expect(turn.turn.id, contains('turn-1'));
    expect(turn.turn.conversationId, contains('conversation-1'));
    expect(delta.turnId, turn.turn.id);
    expect(delta.conversationId, turn.turn.conversationId);
    expect(delta.eventCursor, 'cursor-delta');
    await subscription.cancel();
    await client.close();
  });

  test('does not rewind the latest cursor when replay arrives during subscribe', () async {
    late _FakeTransport transport;
    transport = _FakeTransport(
      {
        'protocol.handshake': _handshakeJson(),
        'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      },
      beforeResponse: (method) {
        if (method == 'event.subscribe') {
          transport.emit({
            'protocolVersion': 1,
            'eventCursor': 'opaque-replay',
            'event': 'conversation.upserted',
            'payload': {'conversation': _conversationJson()},
          });
        }
      },
    );
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', clientDevice: _clientDevice, expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);
    await client.connect();
    expect(client.latestEventCursor, 'opaque-replay');
    await client.close();
  });

  test('broadcasts an event cursor only once for the WebSocket connection', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', clientDevice: _clientDevice, expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);
    await client.connect();
    final received = <GatewayEvent>[];
    final subscription = client.events.listen(received.add);
    final envelope = {
      'protocolVersion': 1,
      'eventCursor': 'opaque-duplicate',
      'event': 'conversation.upserted',
      'payload': {'conversation': _conversationJson()},
    };
    transport.emit(envelope);
    transport.emit(envelope);
    transport.emit({...envelope, 'eventCursor': 'opaque-handshake'});
    await Future<void>.delayed(Duration.zero);
    expect(received.map((event) => event.eventCursor), ['opaque-duplicate']);
    await subscription.cancel();
    await client.close();
  });

  test('turns malformed wire events into a fail-closed stream error', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', clientDevice: _clientDevice, expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);
    await client.connect();
    final expectation = expectLater(client.events.first, throwsA(isA<FormatException>()));
    transport.emit({'protocolVersion': 1, 'eventCursor': 'bad', 'event': 'turn.outputDelta', 'payload': <String, dynamic>{}});
    await expectation;
    await client.close();
  });

  group('snapshot cursor fence', () {
    test('S equals H applies the complete subscribed suffix', () async {
      final controller = StreamController<GatewayEvent>.broadcast(sync: true);
      final window = GatewayEventWindow.forStream('H', controller.stream);
      controller.add(_unknown('A'));
      final applied = <String>[];
      window.install(baselineCursor: 'H', snapshotCursor: 'H', onEvent: (event) => applied.add(event.eventCursor));
      expect(applied, ['A']);
      await window.close();
      await controller.close();
    });

    test('S equals H still drops a duplicated boundary cursor', () async {
      final controller = StreamController<GatewayEvent>.broadcast(sync: true);
      final window = GatewayEventWindow.forStream('H', controller.stream);
      controller.add(_unknown('H'));
      controller.add(_unknown('A'));
      final applied = <String>[];
      window.install(baselineCursor: 'H', snapshotCursor: 'H', onEvent: (event) => applied.add(event.eventCursor));
      expect(applied, ['A']);
      await window.close();
      await controller.close();
    });

    test('drops the prefix through S and applies only later events', () async {
      final controller = StreamController<GatewayEvent>.broadcast(sync: true);
      final window = GatewayEventWindow.forStream('H', controller.stream);
      controller.add(_unknown('S'));
      controller.add(_unknown('A'));
      final applied = <String>[];
      window.install(baselineCursor: 'H', snapshotCursor: 'S', onEvent: (event) => applied.add(event.eventCursor));
      expect(applied, ['A']);
      await window.close();
      await controller.close();
    });

    test('fails closed when S is absent', () async {
      final controller = StreamController<GatewayEvent>.broadcast(sync: true);
      final window = GatewayEventWindow.forStream('H', controller.stream);
      controller.add(_unknown('A'));
      expect(() => window.install(baselineCursor: 'H', snapshotCursor: 'S', onEvent: (_) {}), throwsA(isA<GatewayCursorGapException>()));
      await window.close();
      await controller.close();
    });

    test('uses the last S boundary and suppresses duplicate cursors', () async {
      final controller = StreamController<GatewayEvent>.broadcast(sync: true);
      final window = GatewayEventWindow.forStream('H', controller.stream);
      controller.add(_unknown('S'));
      controller.add(_unknown('discarded'));
      controller.add(_unknown('S'));
      controller.add(_unknown('A'));
      controller.add(_unknown('A'));
      final applied = <String>[];
      window.install(baselineCursor: 'H', snapshotCursor: 'S', onEvent: (event) => applied.add(event.eventCursor));
      expect(applied, ['A']);
      await window.close();
      await controller.close();
    });

    test('does not hide a stream error received before install', () async {
      final controller = StreamController<GatewayEvent>.broadcast(sync: true);
      final window = GatewayEventWindow.forStream('H', controller.stream);
      controller.addError(StateError('socket lost'));
      expect(() => window.install(baselineCursor: 'H', snapshotCursor: 'H', onEvent: (_) {}), throwsStateError);
      await window.close();
      await controller.close();
    });
  });
}

UnknownGatewayEvent _unknown(String cursor) => UnknownGatewayEvent(eventCursor: cursor, name: 'test', payload: const {});

JsonMap _turnEvent(String name, String cursor) {
  final turn = {'deviceId': 'device-test', 'providerPluginId': 'dev.codepet.codex', 'providerInstanceId': 'codex-work', 'nativeResourceId': 'turn-1'};
  final conversation = {'deviceId': 'device-test', 'providerPluginId': 'dev.codepet.codex', 'providerInstanceId': 'codex-work', 'nativeResourceId': 'conversation-1'};
  return {
    'protocolVersion': 1,
    'eventCursor': cursor,
    'event': name,
    'payload': name == 'turn.upserted'
        ? {'turn': {'resource': turn, 'conversation': conversation, 'status': 'running', 'updatedAt': 3000}}
        : {'turn': turn, 'conversation': conversation, 'itemId': 'item-1', 'contentId': 'item-1:text', 'kind': 'text', 'delta': 'live'},
  };
}

class _FakeTransport implements GatewayTransport {
  _FakeTransport(this.responses, {this.beforeResponse});

  final Map<String, JsonMap> responses;
  final void Function(String method)? beforeResponse;
  final StreamController<JsonMap> _events =
      StreamController<JsonMap>.broadcast(sync: true);
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
    beforeResponse?.call(method);
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
    'device': {
      'deviceId': 'device-test',
      'descriptor': {
        'deviceName': 'Test Host',
        'operatingSystem': 'TestOS',
        'systemVersion': '1.0',
      },
      'identityFingerprint': _fingerprint,
    },
    'devices': <Object>[],
    'providers': [
      {
        'route': {'deviceId': 'device-test', 'providerPluginId': 'dev.codepet.codex', 'providerInstanceId': 'codex-work'},
        'pluginId': 'dev.codepet.codex',
        'displayName': 'Codex',
        'harness': {
          'id': 'codex',
          'displayName': 'Codex',
          'version': '1.0.0',
        },
        'status': 'ready',
        'capabilities': {
          'revision': 'revision-1',
          'methods': [
            'conversation.list',
            'conversation.search',
            'conversation.get',
            'turn.send',
          ],
          'turnSend': <String, dynamic>{},
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

JsonMap _turnSendResult({required JsonMap selection}) {
  final conversation = {
    ..._route.toJson(),
    'nativeResourceId': 'conversation-1',
  };
  final turn = {
    ..._route.toJson(),
    'nativeResourceId': 'turn-sent',
  };
  return {
    'accepted': true,
    'turn': {
      'resource': turn,
      'conversation': conversation,
      'status': 'queued',
      'updatedAt': 3000,
    },
    'userItem': {
      'resource': {
        ..._route.toJson(),
        'nativeResourceId': 'item-user',
      },
      'turn': turn,
      'conversation': conversation,
      'kind': 'message',
      'status': 'completed',
      'role': 'user',
      'contents': [
        {
          'contentId': 'item-user:text',
          'kind': 'text',
          'text': '  keep whitespace\n',
        },
      ],
    },
    'effectiveSelection': selection,
  };
}

const _fingerprint = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const _route = GatewayProviderRoute(
  deviceId: 'device-test',
  providerPluginId: 'dev.codepet.codex',
  providerInstanceId: 'codex-work',
);

const _clientDevice = DeviceDescriptor(
  deviceName: 'Test Phone',
  operatingSystem: 'Android',
  systemVersion: '16',
);

JsonMap _fixtureResult(String name) {
  final decoded = jsonDecode(
    File('test/fixtures/gateway_v1/$name').readAsStringSync(),
  ) as Map;
  final response = Map<String, dynamic>.from(decoded['response'] as Map);
  return Map<String, dynamic>.from(response['result'] as Map);
}
