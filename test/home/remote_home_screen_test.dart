import 'dart:async';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_session.dart';
import 'package:codepet_remote/features/home/remote_home_screen.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('listens to events from a device added to the same list instance', (tester) async {
    final client = _EventClient();
    await tester.pumpWidget(MaterialApp(home: _MutableSessionsHarness(client: client)));

    await tester.tap(find.byKey(const Key('add-dynamic-session')));
    await tester.pumpAndSettle();
    expect(find.text('动态事件会话'), findsNothing);

    client.emit(ConversationUpsertedEvent(
      sequence: 1,
      conversation: _conversation('dynamic', '动态事件会话'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('动态事件会话'), findsOneWidget);
  });
}

class _MutableSessionsHarness extends StatefulWidget {
  const _MutableSessionsHarness({required this.client});
  final _EventClient client;
  @override State<_MutableSessionsHarness> createState() => _MutableSessionsHarnessState();
}

class _MutableSessionsHarnessState extends State<_MutableSessionsHarness> {
  final List<DeviceSession> sessions = [];
  int selectedIndex = 0;

  void addSession() {
    final session = DeviceSession(
      device: const PairedDevice(deviceId: 'dynamic', displayName: '动态设备', connectionKind: DeviceConnectionKind.demo),
      clientFactory: () => widget.client,
    );
    setState(() {
      sessions.add(session);
      selectedIndex = sessions.length - 1;
    });
    unawaited(session.connect());
  }

  @override
  void dispose() {
    for (final session in sessions) {
      session.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
    RemoteHomeScreen(
      sessions: sessions,
      selectedIndex: selectedIndex,
      onSelectDevice: (index) => setState(() => selectedIndex = index),
      onAddDevice: () {},
      onOpenSettings: () {},
    ),
    Positioned(
      left: 8,
      bottom: 8,
      child: ElevatedButton(key: const Key('add-dynamic-session'), onPressed: addSession, child: const Text('add')),
    ),
  ]);
}

ConversationSummary _conversation(String id, String title) => ConversationSummary(
  id: id,
  providerId: 'test',
  title: title,
  status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.readOnly,
  workspaceRoot: '/dynamic',
  createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
);

class _EventClient implements GatewayClient {
  final StreamController<GatewayEvent> controller = StreamController<GatewayEvent>.broadcast();
  void emit(GatewayEvent event) => controller.add(event);
  @override Stream<GatewayEvent> get events => controller.stream;
  @override Future<GatewayHandshake> connect() async => const GatewayHandshake(protocolVersion: 0, serverName: 'Test', serverVersion: '1', providers: [], eventSequence: 0);
  @override Future<ConversationPage> listConversations({String? providerId, String? cursor, int limit = 50}) async => const ConversationPage(conversations: [], eventSequence: 0);
  @override Future<ConversationDetail> getConversation(ConversationSummary conversation) async => ConversationDetail(summary: conversation);
  @override Future<void> close() => controller.close();
}
