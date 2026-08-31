import 'dart:async';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_session.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('groups workspaces and sorts projects and recents', () {
    final old = _conversation('old', '/repo/a', 1000);
    final recent = _conversation('recent', '/repo/a', 3000);
    final other = _conversation('other', '/repo/b', 2000);
    final unscoped = _conversation('unscoped', null, 4000);
    final groups = groupConversationsByWorkspace([old, unscoped, other, recent]);
    expect(groups.keys, ['/repo/a', '/repo/b']);
    expect(groups['/repo/a']!.map((item) => item.id), ['recent', 'old']);
    expect(sortRecentConversations([old, recent, other]).map((item) => item.id), ['recent', 'other', 'old']);
  });

  test('sessions isolate projections and disconnect clears runtime data', () async {
    final firstClient = _FakeClient([_conversation('first', '/one', 1000)]);
    final secondClient = _FakeClient([_conversation('second', '/two', 2000)]);
    final first = DeviceSession(device: _device('one'), clientFactory: () => firstClient);
    final second = DeviceSession(device: _device('two'), clientFactory: () => secondClient);
    await Future.wait([first.connect(), second.connect()]);
    expect(first.conversations.single.id, 'first');
    expect(second.conversations.single.id, 'second');
    firstClient.emit(ConversationUpsertedEvent(sequence: 2, conversation: _conversation('first-new', '/one', 3000)));
    await Future<void>.delayed(Duration.zero);
    expect(first.conversations.map((item) => item.id), contains('first-new'));
    expect(second.conversations.single.id, 'second');
    await first.disconnect();
    expect(first.conversations, isEmpty);
    expect(first.handshake, isNull);
    expect(second.conversations.single.id, 'second');
    second.dispose();
  });

  test('failed connect discards client and retry creates a fresh client', () async {
    final failed = _FailingClient();
    final successful = _FakeClient([_conversation('recovered', '/repo', 1000)]);
    final clients = <GatewayClient>[failed, successful];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('retry'),
      clientFactory: () {
        final client = clients[factoryCalls];
        factoryCalls++;
        return client;
      },
    );

    await session.connect();
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, 'first connection failed');
    expect(session.handshake, isNull);
    expect(session.conversations, isEmpty);
    expect(failed.closeCalled, isTrue);

    await session.connect();
    expect(factoryCalls, 2);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.error, isNull);
    expect(session.conversations.single.id, 'recovered');
    session.dispose();
  });
}

PairedDevice _device(String id) => PairedDevice(deviceId: id, displayName: id, connectionKind: DeviceConnectionKind.demo);

ConversationSummary _conversation(String id, String? root, int milliseconds) => ConversationSummary(
  id: id, providerId: 'test', title: id, status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.readOnly, workspaceRoot: root,
  createdAt: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
);

class _FakeClient implements GatewayClient {
  _FakeClient(this.values);
  final List<ConversationSummary> values;
  final StreamController<GatewayEvent> controller = StreamController<GatewayEvent>.broadcast();
  @override Stream<GatewayEvent> get events => controller.stream;
  void emit(GatewayEvent event) => controller.add(event);
  @override Future<GatewayHandshake> connect() async => const GatewayHandshake(protocolVersion: 0, serverName: 'Test', serverVersion: '1', providers: [], eventSequence: 0);
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) async => ConversationPage(conversations: values, eventSequence: 0);
  @override Future<ConversationDetail> getConversation(ConversationSummary conversation) async => ConversationDetail(summary: conversation);
  @override Future<void> close() => controller.close();
}

class _FailingClient implements GatewayClient {
  bool closeCalled = false;
  @override Stream<GatewayEvent> get events => const Stream.empty();
  @override Future<GatewayHandshake> connect() => Future.error('first connection failed');
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationDetail> getConversation(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<void> close() async {
    closeCalled = true;
    throw StateError('close also failed');
  }
}
