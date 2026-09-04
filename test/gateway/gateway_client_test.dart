import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/application/sync/gateway_event_window.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/generated_gateway_mapper.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('performs the generated V1 handshake, subscribe, list and get sequence', () async {
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
      providerId: handshake.providers.single.id,
      projectFilter: const AllConversationFilter(),
      limit: 25,
    );
    final detail = await client.getConversation(page.conversations.single);

    expect(transport.connected, isTrue);
    expect(handshake.protocolVersion, gatewayProtocolVersion);
    expect(handshake.providers.single.id, 'codex-work');
    expect(handshake.providers.single.id, _providerId);
    expect(handshake.providers.single.displayName, 'Codex');
    expect(
      handshake.providers.single.icon,
      'https://cdn.example.com/codex.png',
    );
    expect(handshake.providers.single.runtimeVersion, '1.0.0');
    expect(
      handshake.providers.single.executablePath,
      '/usr/local/bin/codex',
    );
    expect(handshake.providers.single.authenticationDisplayText, 'Signed in');
    expect(handshake.providers.single.usageDisplayText, '72% remaining');
    expect(handshake.providers.single.usageDetails.single['data'], {
      'opaque': true,
    });
    expect(transport.requests[0].method, 'protocol.handshake');
    expect(transport.requests[0].params['device'], _clientDevice.toJson());
    expect(transport.requests[0].params, isNot(contains('clientName')));
    expect(transport.requests[0].params['supportedVersions'], {'minVersion': 1, 'maxVersion': 1});
    expect(transport.requests[1].method, 'event.subscribe');
    expect(transport.requests[1].params['afterCursor'], 'opaque-handshake');
    expect(transport.requests[2].method, 'provider.describe');
    expect(transport.requests[2].params['providerId'], _providerId);
    expect(transport.requests[3].method, 'conversation.list');
    expect(transport.requests[3].params['providerId'], _providerId);
    expect(transport.requests[3].params['projectFilter'], {'kind': 'all'});
    expect(transport.requests[3].params['limit'], 25);
    expect(transport.requests[4].method, 'conversation.get');
    expect(detail.detail.summary.resource!.nativeResourceId, 'conversation-1');
    expect(detail.detail.messages, isEmpty);

    await client.close();
    expect(transport.closed, isTrue);
  });

  test('preserves a Provider-defined permission level', () {
    final json = _conversationJson();
    json['permissionLevel'] = 'opencode-default';

    final conversation = const GeneratedGatewayMapper().conversation(
      sdk.Conversation.fromJson(json),
    );

    expect(conversation.permissionLevel, 'opencode-default');
  });

  test('acquires interaction through the generated method and maps its lease',
      () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'conversation.acquireInteraction': {
        'selection': {
          'accessModeId': 'workspace-write',
          'reasoningEffortId': 'high',
          'model': {'kind': 'flat', 'modelId': 'model-a'},
        },
        'leaseExpiresAt': 2000,
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

    final interaction = await client.acquireInteraction(_domainConversation());

    expect(transport.requests.last.method, 'conversation.acquireInteraction');
    expect(
      transport.requests.last.params['conversation'],
      _resourceJson(_domainConversation().resource!),
    );
    expect(interaction.selection.accessModeId, 'workspace-write');
    expect(interaction.selection.reasoningEffortId, 'high');
    expect(interaction.selection.model?.toJson(), {
      'kind': 'flat',
      'modelId': 'model-a',
    });
    expect(
      interaction.leaseExpiresAt,
      DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );
    await client.close();
  });

  test('marks only the observed conversation activity as read', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'conversation.markRead': {
        'readState': {
          'unread': true,
          'activityVersion': 'activity-8',
        },
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
    final conversation = _domainConversation().withReadState(
      const ConversationReadState(
        unread: true,
        activityVersion: 'activity-7',
      ),
    );

    final state = await client.markConversationRead(conversation);

    expect(transport.requests.last.method, 'conversation.markRead');
    expect(transport.requests.last.params, {
      'conversation': _resourceJson(conversation.resource!),
      'observedActivityVersion': 'activity-7',
    });
    expect(state.unread, isTrue);
    expect(state.activityVersion, 'activity-8');
    await client.close();
  });

  test('generated Gateway SDK rejects non-HTTPS Provider icons', () {
    final provider = Map<String, dynamic>.from(
      (_handshakeJson()['providers'] as List).single as Map,
    );
    (provider['identity'] as Map<String, dynamic>)['icon'] = 'codex';

    expect(
      () => sdk.ProviderSummary.fromJson(provider),
      throwsA(isA<sdk.ProtocolCodecException>()),
    );
  });

  test('sends original text with providerId, revision and flat selection', () async {
    final handshakeJson = _handshakeJson();
    final providerDescription = _providerDescriptionJson();
    final capabilities =
        providerDescription['capabilities'] as Map<String, dynamic>;
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
      'provider.describe': providerDescription,
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
    final conversation = _domainConversation();
    const selection = TurnSendSelection(
      model: FlatModelSelection(modelId: 'model-a'),
    );

    final receipt = await client.sendTurn(
      providerId: _providerId,
      conversation: conversation,
      clientRequestId: 'request-1',
      capabilityRevision: 'revision-1',
      text: '  keep whitespace\n',
      selection: selection,
    );

    expect(transport.requests.last.method, 'turn.send');
    expect(transport.requests.last.params, {
      'conversation': _resourceJson(conversation.resource!),
      'clientRequestId': 'request-1',
      'capabilityRevision': 'revision-1',
      'input': {'kind': 'text', 'text': '  keep whitespace\n'},
      'selection': {
        'model': {'kind': 'flat', 'modelId': 'model-a'},
      },
    });
    expect(receipt.clientRequestId, 'request-1');
    expect(receipt.inputItem!.content, '  keep whitespace\n');
    expect(receipt.turn.conversationId, conversation.id);
    await client.close();
  });

  test('accepts a required null userItem without fabricating history', () async {
    final response = _turnSendResult(selection: const {});
    response['userItem'] = null;
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'turn.send': response,
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();
    final conversation = _domainConversation();

    final receipt = await client.sendTurn(
      providerId: _providerId,
      conversation: conversation,
      clientRequestId: 'request-null-item',
      capabilityRevision: 'revision-1',
      text: 'accepted without an immediate item',
      selection: const TurnSendSelection(),
    );

    expect(receipt.inputItem, isNull);
    expect(receipt.turn.status, TurnStatus.queued);
    final missingUserItem = {...response}..remove('userItem');
    expect(
      () => sdk.TurnSendResponse.fromJson(missingUserItem),
      throwsA(isA<sdk.ProtocolCodecException>()),
    );
    await client.close();
  });

  test('interrupts a routed active turn and resolves an advertised approval', () async {
    final description = _providerDescriptionJson();
    final capabilities = description['capabilities'] as Map<String, dynamic>;
    (capabilities['methods'] as List<String>)
        .addAll(['turn.interrupt', 'approval.resolve']);
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'provider.describe': description,
      'turn.interrupt': {'turn': _turnJson('turn-active', status: 'interrupted')},
      'approval.resolve': {'approval': _approvalJson(status: 'approved', decision: 'approve')},
    });
    final client = ProtocolGatewayClient(transport: transport, clientId: 'client-test', clientDevice: _clientDevice, expectedDeviceId: 'device-test', expectedIdentityFingerprint: _fingerprint);
    await client.connect();
    final conversation = _domainConversation();
    final turn = const GeneratedGatewayMapper().turn(sdk.TurnTask.fromJson(_turnJson('turn-active')));
    final approval = const GeneratedGatewayMapper().approval(sdk.Approval.fromJson(_approvalJson(status: 'pending')));

    final interrupted = await client.interruptTurn(conversation: conversation, turn: turn);
    expect(transport.requests.last.method, 'turn.interrupt');
    expect(interrupted.status, TurnStatus.interrupted);
    final resolved = await client.resolveApproval(approval: approval, decision: ApprovalDecision.approve);
    expect(transport.requests.last.method, 'approval.resolve');
    expect(transport.requests.last.params['decision'], 'approve');
    expect(resolved.approvalDecision, ApprovalDecision.approve);
    await client.close();
  });

  test('creates a routed conversation through the generated SDK', () async {
    final handshake = _handshakeJson();
    final providerDescription = _providerDescriptionJson();
    final capabilities =
        providerDescription['capabilities'] as Map<String, dynamic>;
    (capabilities['methods'] as List).add('conversation.create');
    final transport = _FakeTransport({
      'protocol.handshake': handshake,
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'provider.describe': providerDescription,
      'conversation.create': {'conversation': _conversationJson()},
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();

    final conversation = await client.createConversation(
      providerId: _providerId,
      title: 'New task',
      permissionLevel: PermissionLevel.workspaceWrite,
      model: 'model-a',
      reasoningEffort: 'high',
      workspaceRoot: '/workspace/project',
      workspaceMode: 'worktree',
      project: const RoutedResourceId(
        providerId: _providerId,
        nativeResourceId: 'project-1',
      ),
    );

    expect(conversation.title, 'Test conversation');
    expect(
      transport.requests.last.params,
      {
        'providerId': _providerId,
        'title': 'New task',
        'permissionLevel': 'workspace-write',
        'model': 'model-a',
        'reasoningEffort': 'high',
        'workspaceRoot': '/workspace/project',
        'workspaceMode': 'worktree',
        'project': {
          ..._providerResourceFields,
          'nativeResourceId': 'project-1',
        },
      },
    );
    await client.close();
  });

  test('maps project CRUD and explicit conversation project filters', () async {
    final handshake = _handshakeJson();
    final providerDescription = _providerDescriptionJson();
    final capabilities =
        providerDescription['capabilities'] as Map<String, dynamic>;
    (capabilities['methods'] as List<String>).addAll(const <String>[
      'project.list',
      'project.get',
      'project.create',
      'project.update',
      'project.delete',
    ]);
    final projectJson = _projectJson();
    final transport = _FakeTransport({
      'protocol.handshake': handshake,
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'provider.describe': providerDescription,
      'project.list': {
        'projects': [projectJson],
        'pageInfo': {'nextCursor': 'project-page-2'},
        'snapshotCursor': 'project-snapshot',
      },
      'project.get': {'project': projectJson},
      'project.create': {'project': projectJson},
      'project.update': {'project': projectJson},
      'project.delete': <String, dynamic>{},
      'conversation.list': {
        'conversations': [_conversationJson()],
        'pageInfo': <String, dynamic>{},
        'snapshotCursor': 'conversation-snapshot',
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

    final page = await client.listProjects(providerId: _providerId, limit: 20);
    final project = page.projects.single;
    expect(project.name, 'codepet-remote');
    expect(project.roots.single.path, '/workspace/codepet-remote');
    expect(project.metadata, {'team': 'remote'});
    expect(page.nextCursor, 'project-page-2');

    await client.listConversations(
      providerId: _providerId,
      projectFilter: const StandaloneConversationFilter(),
    );
    expect(transport.requests.last.params['projectFilter'], {
      'kind': 'standalone',
    });

    await client.listConversations(
      providerId: _providerId,
      projectFilter: ProjectConversationFilter(project.resource),
    );
    expect(transport.requests.last.params['projectFilter'], {
      'kind': 'project',
      'project': _resourceJson(project.resource),
    });

    await client.getProject(project.resource);
    await client.createProject(
      providerId: _providerId,
      idempotencyKey: 'create-project-1',
      name: 'codepet-remote',
      roots: const [ProjectRoot(path: '/workspace/codepet-remote')],
      metadata: const {'team': 'remote'},
    );
    expect(transport.requests.last.params['idempotencyKey'], 'create-project-1');
    await client.updateProject(
      project: project.resource,
      roots: const [],
      metadata: const {},
    );
    expect(transport.requests.last.params['roots'], isEmpty);
    expect(transport.requests.last.params['metadata'], isEmpty);
    await client.deleteProject(project.resource);
    expect(transport.requests.last.params, {
      'project': _resourceJson(project.resource),
    });
    await client.close();
  });

  test('preserves grouped model identity and rejects a mismatched receipt', () async {
    final handshakeJson = _handshakeJson();
    final providerDescription = _providerDescriptionJson();
    final capabilities =
        providerDescription['capabilities'] as Map<String, dynamic>;
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
      ..._providerResourceFields,
      'nativeResourceId': 'another-conversation',
    };
    final transport = _FakeTransport({
      'protocol.handshake': handshakeJson,
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      'provider.describe': providerDescription,
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
    final conversation = _domainConversation();

    await expectLater(
      client.sendTurn(
        providerId: _providerId,
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
      providerId: handshake.providers.single.id,
      projectFilter: const AllConversationFilter(),
    );
    final snapshot = await client.getConversation(page.conversations.single);
    final history = snapshot.detail.committedMessages;

    expect(handshake.deviceDescriptor.deviceName, 'MacBook');
    expect(handshake.deviceDescriptor.operatingSystem, 'macOS');
    expect(history, hasLength(5));
    expect(history[0].role, MessageRole.user);
    expect(history[0].content, 'Show the Gateway history.');
    expect(history[1].kind, 'reasoning');
    expect(history[1].content, 'Inspecting the stored thread items.');
    expect(history[2].kind, 'command');
    expect(history[2].title, 'Run git status --short');
    expect(
      history[2].contents.map((content) => content.kind),
      ['command', 'output'],
    );
    expect(history[2].tool?.name, 'shell');
    expect(history[2].tool?.command, 'git status --short');
    expect(history[2].tool?.cwd, '/workspace');
    expect(history[2].tool?.exitCode, 0);
    expect(history[2].tool?.durationMs, 24);
    expect(history[2].tool?.resultContent.single.text, 'working tree clean');
    expect(history[3].kind, 'approval');
    expect(history[3].approvalStatus, 'approved');
    expect(history[4].role, MessageRole.assistant);
    expect(history[4].content, 'The committed history is ready.');
    expect(history[4].contentIds, ['message-agent-01:text']);
    await client.close();
  });

  test('shrinks conversation history pages after an oversized response',
      () async {
    final transport = _FakeTransport(
      {
        'protocol.handshake': _handshakeJson(),
        'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      },
      responseBuilder: (method, params, id) {
        if (method != 'conversation.get') return null;
        final limit = params['limit'] as int;
        final cursor = params['cursor'] as String?;
        if (cursor == null && limit > 1) {
          return {
            'jsonrpc': '2.0',
            'id': id,
            'error': {
              'code': -32000,
              'message':
                  'Provider response exceeds the 16777216-byte JSON-line limit',
              'data': {
                'code': 'provider_response_too_large',
                'retryable': false,
              },
            },
          };
        }
        final older = cursor == 'older-page';
        return {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'conversation': _conversationJson(),
            'items': [
              _historyItemJson(
                older ? 'older-item' : 'newer-item',
                older ? 'older' : 'newer',
              ),
            ],
            'pageInfo': older ? <String, dynamic>{} : {'nextCursor': 'older-page'},
            'snapshotCursor': 'opaque-snapshot',
          },
        };
      },
    );
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();

    final snapshot = await client.getConversation(_domainConversation());

    final requests = transport.requests
        .where((request) => request.method == 'conversation.get')
        .toList(growable: false);
    expect(
      requests.map((request) => request.params['limit']),
      [40, 20, 10, 5, 2, 1, 1],
    );
    expect(
      requests.map((request) => request.params['cursor']),
      [null, null, null, null, null, null, 'older-page'],
    );
    expect(
      snapshot.detail.committedMessages.map((message) => message.content),
      ['older', 'newer'],
    );
    await client.close();
  });

  test('maps conversation selection and active turn from the routed snapshot', () async {
    final handshakeJson = _handshakeJson();
    final providerDescription = _providerDescriptionJson();
    final capabilities =
        providerDescription['capabilities'] as Map<String, dynamic>;
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
        ..._providerResourceFields,
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
      'provider.describe': providerDescription,
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
    final requested = _domainConversation();

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
      providerId: handshake.providers.single.id,
      projectFilter: const AllConversationFilter(),
    );

    expect(
      () => client.getConversation(page.conversations.single),
      throwsFormatException,
    );
    await client.close();
  });

  test('sends providerId-scoped search pagination and validates its providerId', () async {
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
      providerId: handshake.providers.single.id,
      searchTerm: 'gateway protocol',
      cursor: 'search-cursor',
      limit: 20,
    );

    expect(page.conversations, hasLength(1));
    expect(page.nextCursor, 'search-next');
    expect(transport.requests.last.method, 'conversation.search');
    expect(transport.requests.last.params, {
      'providerId': _providerId,
      'searchTerm': 'gateway protocol',
      'cursor': 'search-cursor',
      'limit': 20,
    });

    await client.getConversation(page.conversations.single);
    expect(transport.requests.last.method, 'conversation.get');
    expect(
      transport.requests.last.params['conversation'],
      _resourceJson(page.conversations.single.resource!),
    );

    transport.responses['conversation.search'] = {
      'conversations': [
        _conversationJson()
          ..['resource'] = {
            'providerId': 'other',
            'nativeResourceId': 'conversation-1',
          },
      ],
      'pageInfo': <String, dynamic>{},
      'snapshotCursor': 'opaque-search',
    };
    await expectLater(
      client.searchConversations(
        providerId: handshake.providers.single.id,
        searchTerm: 'gateway protocol',
      ),
      throwsFormatException,
    );
    await client.close();
  });

  test('rejects an empty opaque Provider id in the handshake', () async {
    final handshake = _handshakeJson();
    final providers = handshake['providers'] as List;
    final provider = Map<String, dynamic>.from(providers.single as Map);
    provider['id'] = '';
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

  test('does not persist an endpoint after certificate rejection', () async {
    final endpointRefreshes = <Uri>[];
    final transport = _FakeTransport(
      const {},
      selectedGatewayUri: Uri.parse(
        'wss://wrong-certificate.test/remote/v1/gateway',
      ),
      connectError: const HandshakeException('certificate pin mismatch'),
    );
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
      onValidatedEndpoint: endpointRefreshes.add,
    );

    await expectLater(client.connect(), throwsA(isA<HandshakeException>()));

    expect(endpointRefreshes, isEmpty);
    await client.close();
  });

  test('persists an endpoint only after handshake and subscribe succeed', () async {
    final endpoint = Uri.parse('wss://validated.test/remote/v1/gateway');
    final rejectedRefreshes = <Uri>[];
    final rejectedTransport = _FakeTransport(
      {
        'protocol.handshake': _handshakeJson(),
        'event.subscribe': {'subscribedAfterCursor': 'wrong-cursor'},
      },
      selectedGatewayUri: endpoint,
    );
    final rejectedClient = ProtocolGatewayClient(
      transport: rejectedTransport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
      onValidatedEndpoint: rejectedRefreshes.add,
    );

    await expectLater(
      rejectedClient.connect(),
      throwsA(isA<GatewayConnectionException>()),
    );
    expect(rejectedRefreshes, isEmpty);
    await rejectedClient.close();

    late _FakeTransport acceptedTransport;
    final requestsAtRefresh = <List<String>>[];
    acceptedTransport = _FakeTransport(
      {
        'protocol.handshake': _handshakeJson(),
        'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      },
      selectedGatewayUri: endpoint,
    );
    final acceptedClient = ProtocolGatewayClient(
      transport: acceptedTransport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
      onValidatedEndpoint: (validated) {
        expect(validated, endpoint);
        requestsAtRefresh.add(
          acceptedTransport.requests
              .map((request) => request.method)
              .toList(growable: false),
        );
      },
    );

    await acceptedClient.connect();

    expect(requestsAtRefresh, [
      ['protocol.handshake', 'event.subscribe'],
    ]);
    await acceptedClient.close();
  });

  test('does not persist an ephemeral endpoint after handshake and subscribe', () async {
    final endpoint = Uri.parse('wss://10.0.2.2:47622/remote/v1/gateway');
    final endpointRefreshes = <Uri>[];
    final transport = _FakeTransport(
      {
        'protocol.handshake': _handshakeJson(),
        'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
      },
      selectedGatewayUri: endpoint,
      shouldPersistSelectedGatewayUri: false,
    );
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
      onValidatedEndpoint: endpointRefreshes.add,
    );

    await client.connect();

    expect(
      transport.requests.map((request) => request.method),
      ['protocol.handshake', 'event.subscribe'],
    );
    expect(endpointRefreshes, isEmpty);
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
    expect((event as ConversationUpsertedEvent).conversation.resource!.nativeResourceId, 'conversation-1');
    await client.close();
  });

  test('projects project.changed with routed identity and change type',
      () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();
    final eventFuture = client.events.first;

    transport.emit({
      'eventCursor': 'opaque-project-event',
      'event': 'project.changed',
      'payload': {
        'project': _projectJson()['resource'],
        'changeType': 'updated',
      },
    });

    final event = await eventFuture as ProjectChangedEvent;
    expect(event.project.nativeResourceId, 'project-1');
    expect(event.changeType, ProjectChangeType.updated);
    await client.close();
  });

  test('projects conversation activity with its Host version', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    await client.connect();
    final eventFuture = client.events.first;

    transport.emit({
      'protocolVersion': 1,
      'eventCursor': 'opaque-activity-8',
      'event': 'conversation.activityChanged',
      'payload': {
        'conversation': _conversationJson()['resource'],
        'activityVersion': 'activity-8',
      },
    });

    final event = await eventFuture as ConversationActivityChangedEvent;
    expect(event.conversationId, _domainConversation().id);
    expect(event.activityVersion, 'activity-8');
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
          'providerId': 'other-work',
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

  test('projects typed conversation item upserts', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    final received = <GatewayEvent>[];
    final subscription = client.events.listen(received.add);
    await client.connect();

    transport.emit({
      'protocolVersion': 1,
      'eventCursor': 'cursor-item',
      'event': 'conversation.itemUpserted',
      'payload': {
        'item': {
          'resource': {..._providerResourceFields, 'nativeResourceId': 'command-live'},
          'turn': {..._providerResourceFields, 'nativeResourceId': 'turn-1'},
          'conversation': {
            ..._providerResourceFields,
            'nativeResourceId': 'conversation-1',
          },
          'kind': 'command',
          'status': 'completed',
          'title': 'git status --short',
          'contents': const [],
          'tool': {
            'callId': 'command-live',
            'name': 'shell',
            'category': 'command',
            'origin': {'kind': 'builtin', 'name': 'codex'},
            'input': {'command': 'git status --short'},
            'command': {'command': 'git status --short', 'exitCode': 0},
          },
        },
      },
    });
    await Future<void>.delayed(Duration.zero);

    final event = received.single as ConversationItemUpsertedEvent;
    expect(event.item.tool?.name, 'shell');
    expect(event.item.tool?.exitCode, 0);
    expect(event.conversationId, contains('conversation-1'));
    await subscription.cancel();
    await client.close();
  });

  test('projects approval requested and resolved events', () async {
    final transport = _FakeTransport({
      'protocol.handshake': _handshakeJson(),
      'event.subscribe': {'subscribedAfterCursor': 'opaque-handshake'},
    });
    final client = ProtocolGatewayClient(
      transport: transport,
      clientId: 'client-test',
      clientDevice: _clientDevice,
      expectedDeviceId: 'device-test',
      expectedIdentityFingerprint: _fingerprint,
    );
    final received = <GatewayEvent>[];
    final subscription = client.events.listen(received.add);
    await client.connect();

    transport.emit(_approvalEvent(
      'approval.requested',
      'cursor-approval-requested',
      status: 'pending',
    ));
    transport.emit(_approvalEvent(
      'approval.resolved',
      'cursor-approval-resolved',
      status: 'approved',
      decision: 'approve',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(received, everyElement(isA<ApprovalChangedEvent>()));
    final requested = received[0] as ApprovalChangedEvent;
    final resolved = received[1] as ApprovalChangedEvent;
    expect(requested.approval.approvalStatus, 'pending');
    expect(requested.approval.content, 'Run the command');
    expect(resolved.approval.approvalStatus, 'approved');
    expect(resolved.conversationId, contains('conversation-1'));
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
  final turn = {..._providerResourceFields, 'nativeResourceId': 'turn-1'};
  final conversation = {
    ..._providerResourceFields,
    'nativeResourceId': 'conversation-1',
  };
  return {
    'protocolVersion': 1,
    'eventCursor': cursor,
    'event': name,
    'payload': name == 'turn.upserted'
        ? {'turn': {'resource': turn, 'conversation': conversation, 'status': 'running', 'updatedAt': 3000}}
        : {'turn': turn, 'conversation': conversation, 'itemId': 'item-1', 'contentId': 'item-1:text', 'kind': 'text', 'delta': 'live'},
  };
}

JsonMap _approvalEvent(
  String name,
  String cursor, {
  required String status,
  String? decision,
}) {
  final approval = _approvalJson(status: status, decision: decision);
  return {'protocolVersion': 1, 'eventCursor': cursor, 'event': name, 'payload': {'approval': approval}};
}

JsonMap _approvalJson({required String status, String? decision}) {
  final approval = <String, Object?>{
    'resource': {..._providerResourceFields, 'nativeResourceId': 'approval-1'},
    'conversation': {..._providerResourceFields, 'nativeResourceId': 'conversation-1'},
    'turn': {..._providerResourceFields, 'nativeResourceId': 'turn-1'},
    'kind': 'command',
    'title': 'Run command',
    'description': 'Run the command',
    'status': status,
    'decisions': ['approve', 'deny'],
    'requestedAt': 3000,
  };
  if (decision != null) {
    approval['resolvedAt'] = 4000;
    approval['decision'] = decision;
  }
  return approval;
}

class _FakeTransport
    implements GatewayTransport, EndpointAwareGatewayTransport,
        EndpointPersistenceAwareGatewayTransport {
  _FakeTransport(
    this.responses, {
    this.beforeResponse,
    this.responseBuilder,
    this.selectedGatewayUri,
    this.shouldPersistSelectedGatewayUri = true,
    this.connectError,
  });

  final Map<String, JsonMap> responses;
  final void Function(String method)? beforeResponse;
  final Object? Function(String method, JsonMap params, String id)?
      responseBuilder;
  @override
  final Uri? selectedGatewayUri;
  @override
  final bool shouldPersistSelectedGatewayUri;
  final Object? connectError;
  final StreamController<JsonMap> _events =
      StreamController<JsonMap>.broadcast(sync: true);
  final List<_RequestRecord> requests = [];
  bool connected = false;
  bool closed = false;

  @override
  Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    final error = connectError;
    if (error != null) throw error;
    connected = true;
  }

  @override
  Future<Object?> request(Map<String, Object?> request) async {
    final method = request['method'] as String;
    final params = Map<String, dynamic>.from(request['params'] as Map);
    requests.add(_RequestRecord(method, params));
    beforeResponse?.call(method);
    final customResponse = responseBuilder?.call(
      method,
      params,
      request['id'] as String,
    );
    if (customResponse != null) return customResponse;
    var response = responses[method];
    if (response == null && method == 'provider.describe') {
      response = _providerDescriptionJson();
    }
    if (response == null) {
      throw StateError('No response for $method');
    }
    return {
      'jsonrpc': '2.0',
      'id': request['id'],
      'result': response,
    };
  }

  void emit(JsonMap event) {
    _events.add({
      'jsonrpc': '2.0',
      'method': event['event'],
      'params': {
        'eventCursor': event['eventCursor'],
        'payload': event['payload'],
      },
    });
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
    'protocol': {'version': 1},
    'device': {
      'name': 'Test Host',
      'operatingSystem': 'TestOS',
      'systemVersion': '1.0',
    },
    'providers': [_providerSummaryJson()],
    'eventCursor': 'opaque-handshake',
  };
}

JsonMap _providerSummaryJson() => {
      'id': _providerId,
      'identity': {
        'displayName': 'Codex',
        'icon': 'https://cdn.example.com/codex.png',
      },
      'runtime': {
        'status': 'ready',
        'version': '1.0.0',
        'executablePath': '/usr/local/bin/codex',
        'authentication': {
          'status': 'signed-in',
          'displayText': 'Signed in',
        },
        'usage': {
          'displayText': '72% remaining',
          'details': [
            {
              'namespace': 'dev.codepet.codex',
              'schemaVersion': '1',
              'data': {'opaque': true},
            },
          ],
        },
      },
      'capabilities': {'revision': 'revision-1'},
    };

JsonMap _providerDescriptionJson() => {
      'provider': _providerSummaryJson(),
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
    };

JsonMap _conversationJson() {
  return {
    'resource': {
      ..._providerResourceFields,
      'nativeResourceId': 'conversation-1',
    },
    'project': null,
    'title': 'Test conversation',
    'status': 'idle',
    'permissionLevel': 'read-only',
    'createdAt': 1000,
    'updatedAt': 2000,
  };
}

JsonMap _projectJson() => {
      'resource': {
        ..._providerResourceFields,
        'nativeResourceId': 'project-1',
      },
      'name': 'codepet-remote',
      'roots': [
        {'path': '/workspace/codepet-remote'},
      ],
      'metadata': {'team': 'remote'},
      'position': 0,
      'createdAt': 1000,
      'updatedAt': 2000,
    };

JsonMap _historyItemJson(String itemId, String text) {
  final conversation = {
    ..._providerResourceFields,
    'nativeResourceId': 'conversation-1',
  };
  return {
    'resource': {..._providerResourceFields, 'nativeResourceId': itemId},
    'turn': {..._providerResourceFields, 'nativeResourceId': '$itemId-turn'},
    'conversation': conversation,
    'kind': 'message',
    'status': 'completed',
    'role': 'assistant',
    'contents': [
      {'contentId': '$itemId:text', 'kind': 'text', 'text': text},
    ],
  };
}

JsonMap _turnSendResult({required JsonMap selection}) {
  final conversation = {
    ..._providerResourceFields,
    'nativeResourceId': 'conversation-1',
  };
  final turn = {
    ..._providerResourceFields,
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
        ..._providerResourceFields,
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

JsonMap _turnJson(String turnId, {String status = 'running'}) => {
  'resource': {..._providerResourceFields, 'nativeResourceId': turnId},
  'conversation': {..._providerResourceFields, 'nativeResourceId': 'conversation-1'},
  'status': status,
  'updatedAt': 3000,
};

ConversationSummary _domainConversation() =>
    const GeneratedGatewayMapper().conversation(
      sdk.Conversation.fromJson(_conversationJson()),
    );

JsonMap _resourceJson(RoutedResourceId resource) => {
      'providerId': resource.providerId,
      'nativeResourceId': resource.nativeResourceId,
    };

const _fingerprint = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

const _providerId = 'codex-work';
const JsonMap _providerResourceFields = {'providerId': _providerId};

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
