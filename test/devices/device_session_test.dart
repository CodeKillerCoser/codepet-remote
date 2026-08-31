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
    firstClient.emit(ConversationUpsertedEvent(eventCursor: 'event-2', conversation: _conversation('first-new', '/one', 3000)));
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

  test('reconnect while online closes the old client and creates a new one', () async {
    final first = _FakeClient([_conversation('old', '/repo', 1000)]);
    final second = _FakeClient([_conversation('new', '/repo', 2000)]);
    final clients = [first, second];
    var calls = 0;
    final session = DeviceSession(
      device: _device('reconnect'),
      clientFactory: () => clients[calls++],
    );
    await session.connect();
    await session.connect();
    expect(calls, 2);
    expect(first.closed, isTrue);
    expect(session.conversations.single.id, 'new');
    session.dispose();
  });

  test('event stream failure clears the complete runtime projection', () async {
    final client = _FakeClient([_conversation('stale', '/repo', 1000)]);
    final session = DeviceSession(device: _device('lost'), clientFactory: () => client);
    await session.connect();
    client.controller.addError(StateError('socket lost'));
    await Future<void>.delayed(Duration.zero);
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.handshake, isNull);
    expect(session.conversations, isEmpty);
    expect(client.closed, isTrue);
    session.dispose();
  });

  test('re-pairing the same device replaces and disposes its old session', () async {
    final oldClient = _FakeClient(const []);
    final replacementClient = _FakeClient(const []);
    final sessions = [DeviceSession(device: _device('same'), clientFactory: () => oldClient)];
    await sessions.single.connect();
    final replacement = DeviceSession(device: _device('same'), clientFactory: () => replacementClient);
    final index = await replaceDeviceSession(sessions, replacement);
    expect(index, 0);
    expect(sessions, [replacement]);
    expect(oldClient.closed, isTrue);
    replacement.dispose();
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
  String _cursor = 'handshake';
  bool closed = false;
  @override Stream<GatewayEvent> get events => controller.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; controller.add(event); }
  @override Future<GatewayHandshake> connect() async => const GatewayHandshake(protocolVersion: 1, serverName: 'Test', serverVersion: '1', providers: [], eventCursor: 'handshake');
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) async => ConversationPage(conversations: values, snapshotCursor: 'handshake');
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: _cursor);
  @override Future<void> close() async { closed = true; await controller.close(); }
}

class _FailingClient implements GatewayClient {
  bool closeCalled = false;
  @override Stream<GatewayEvent> get events => const Stream.empty();
  @override String? get latestEventCursor => null;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(null, events);
  @override Future<GatewayHandshake> connect() => Future.error('first connection failed');
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<void> close() async {
    closeCalled = true;
    throw StateError('close also failed');
  }
}
