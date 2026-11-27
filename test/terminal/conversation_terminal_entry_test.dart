import 'dart:convert';

import 'package:codepet_remote/application/ports/terminal_gateway.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/features/conversations/conversation_detail_screen.dart';
import 'package:codepet_remote/gateway/demo_gateway_client.dart';
import 'package:codepet_remote/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'terminal_test_gateway.dart';

void main() {
  testWidgets(
    'conversation terminal preserves draft and connection; shortcuts respect VT input mode',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _TerminalDemoClient();
      client.terminalGateway.emit('\x1b[?1h\x1b[32m电脑输出\x1b[0m\r\n');
      final session = DeviceSession(
        device: const PairedDevice(
          deviceId: 'terminal-test',
          displayName: '电脑',
          connectionKind: DeviceConnectionKind.demo,
        ),
        clientFactory: () => client,
        autoReconnect: false,
      );
      final connecting = session.connect();
      await tester.pump(const Duration(milliseconds: 300));
      await connecting;
      final listing = client.listConversations(
        providerId: 'codex-demo',
        projectFilter: const AllConversationFilter(),
      );
      await tester.pump(const Duration(milliseconds: 200));
      final conversations = await listing;
      final conversation = conversations.conversations.firstWhere(
        (c) => c.status == ConversationStatus.idle,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light,
          home: ConversationDetailScreen(
            session: session,
            conversation: conversation,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final draft = find.byKey(const Key('turn-input'));
      expect(tester.widget<TextField>(draft).enabled, isTrue);
      await tester.enterText(draft, '保留这段草稿');
      expect(tester.widget<TextField>(draft).controller!.text, '保留这段草稿');
      await tester.tap(find.byKey(const Key('open-conversation-terminal')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
      expect(session.connectionState, DeviceConnectionState.online);
      expect(client.terminalGateway.opens, 1);
      final sheet = find.byKey(const Key('snap-bottom-sheet'));
      final height = tester.getSize(sheet).height;
      await tester.ensureVisible(find.text('↑'));
      await tester.tap(find.text('↑'));
      await tester.pump();
      expect(utf8.decode(client.terminalGateway.inputs.last.$2), '\x1bOA');
      expect(tester.getSize(sheet).height, height);
      await tester.tap(find.byKey(const Key('close-snap-sheet')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.widget<TextField>(draft).controller!.text, '保留这段草稿');
      expect(session.connectionState, DeviceConnectionState.online);
      expect(client.terminalGateway.closes, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      session.dispose();
      await tester.pump();
    },
  );
}

class _TerminalDemoClient extends DemoGatewayClient
    implements TerminalGatewayHost {
  @override
  final TestTerminalGateway terminalGateway = TestTerminalGateway();
}
