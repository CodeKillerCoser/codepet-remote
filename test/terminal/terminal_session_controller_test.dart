import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/application/ports/terminal_gateway.dart';
import 'package:codepet_remote/application/terminal/terminal_session_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/core.dart';

import 'terminal_test_gateway.dart';

void main() {
  test(
    'cursor application mode is independent from keypad application mode',
    () {
      final controller = TerminalSessionController(gateway: () => null);
      final input = <String>[];
      controller.terminal.onOutput = input.add;
      controller.terminal.write('\x1b[?1h');
      controller.terminal.keyInput(TerminalKey.arrowUp);
      controller.terminal.write('\x1b[?1l\x1b=');
      controller.terminal.keyInput(TerminalKey.arrowUp);
      controller.terminal.keyInput(TerminalKey.keyC, ctrl: true);
      expect(input, ['\x1bOA', '\x1b[A', '\x03']);
      controller.dispose();
    },
  );

  testWidgets(
    'raw PTY chunks preserve UTF8, ANSI attributes and cursor operations',
    (tester) async {
      final gateway = TestTerminalGateway();
      final encoded = Uint8List.fromList(
        utf8.encode('\x1b[31m电脑\x1b[0m\r\nprogress 10%\r\x1b[2Kdone'),
      );
      gateway.chunks.addAll([
        Uint8List.sublistView(encoded, 0, 6),
        Uint8List.sublistView(encoded, 6, 9),
        Uint8List.sublistView(encoded, 9),
      ]);
      final controller = TerminalSessionController(gateway: () => gateway);
      controller.attach();
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 130));
      }
      final text = controller.terminal.buffer.getText();
      expect(text, contains('电脑'));
      expect(text, contains('done'));
      expect(text, isNot(contains('progress')));
      expect(text, isNot(contains('\uFFFD')));
      expect(controller.terminal.buffer.lines[0].getForeground(0), isNot(0));
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'dismiss/reopen keeps same PTY/model; offline reconnect reads without reopening',
    (tester) async {
      final client = TestTerminalGateway()..emit('retained');
      TerminalGateway? available = client;
      final controller = TerminalSessionController(gateway: () => available);
      controller.attach();
      await tester.pump(const Duration(milliseconds: 200));
      final model = controller.terminal;
      controller.detach();
      final reads = client.reads;
      await tester.pump(const Duration(seconds: 1));
      expect(client.reads, reads);
      expect(client.closes, 0);
      controller.attach();
      await tester.pump();
      expect(client.opens, 1);
      expect(controller.terminal, same(model));
      available = null;
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.status, TerminalSessionStatus.offline);
      available = client;
      client.emit(' again');
      await tester.pump(const Duration(milliseconds: 600));
      expect(controller.status, TerminalSessionStatus.running);
      expect(controller.terminal.buffer.getText(), contains('retained again'));
      expect(client.opens, 1);
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'input is ordered; unknown write outcome stops further input without replay',
    (tester) async {
      final client = TestTerminalGateway();
      final controller = TerminalSessionController(gateway: () => client);
      controller.attach();
      await tester.pump();
      client.writeGate = Completer<void>();
      controller.send('a');
      controller.send('b');
      await tester.pump();
      expect(client.inputs.map((input) => utf8.decode(input.$2)), ['a']);
      client.writeGate!.complete();
      await tester.pump();
      expect(client.inputs.map((input) => input.$1), [1, 2]);
      client.writeError = TimeoutException('lost ack');
      controller.send('dangerous-command\r');
      controller.send('must-not-send');
      await tester.pump();
      expect(controller.canInput, isFalse);
      expect(client.inputs.length, 3);
      await controller.retry();
      controller.send('still-must-not-send');
      await tester.pump();
      expect(client.inputs.length, 3);
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'resize coalesces; explicit restart closes PTY before new key/model',
    (tester) async {
      final client = TestTerminalGateway();
      final controller = TerminalSessionController(gateway: () => client);
      controller.attach();
      await tester.pump();
      controller.resize(70, 20);
      controller.resize(90, 40);
      await tester.pump(const Duration(milliseconds: 150));
      expect(client.sizes.last, (90, 40));
      final model = controller.terminal;
      await controller.restart();
      await tester.pump();
      expect(client.closes, 1);
      expect(client.opens, 2);
      expect(client.keys.toSet().length, 2);
      expect(controller.terminal, isNot(same(model)));
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'a late read from ended PTY never contaminates the new terminal',
    (tester) async {
      final client = TestTerminalGateway();
      client.readGate = Completer<RemoteTerminalOutput>();
      final controller = TerminalSessionController(gateway: () => client);
      controller.attach();
      await tester.pump();
      final oldRead = client.readGate!;
      await controller.restart();
      client.readGate = null;
      client.emit('new-session');
      oldRead.complete(
        RemoteTerminalOutput(
          bytes: Uint8List.fromList(utf8.encode('stale')),
          nextOffset: 5,
          exited: false,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(controller.terminal.buffer.getText(), contains('new-session'));
      expect(controller.terminal.buffer.getText(), isNot(contains('stale')));
      controller.dispose();
      await tester.pump();
    },
  );

  testWidgets('old Host and bounded-output gap remain local terminal states', (
    tester,
  ) async {
    final old = TestTerminalGateway()..supported = false;
    final unsupported = TerminalSessionController(gateway: () => old);
    unsupported.attach();
    await tester.pump();
    expect(unsupported.status, TerminalSessionStatus.unsupported);
    expect(old.opens, 0);
    unsupported.detach();
    old.supported = true;
    unsupported.attach();
    await tester.pump();
    expect(unsupported.status, TerminalSessionStatus.running);
    unsupported.dispose();
    final gap = TestTerminalGateway()
      ..readError = const GatewayProtocolException(
        code: 'terminal_output_expired',
        message: 'output expired',
        retryable: false,
      );
    final failed = TerminalSessionController(gateway: () => gap);
    final healthyClient = TestTerminalGateway()..emit('healthy');
    final healthy = TerminalSessionController(gateway: () => healthyClient);
    failed.attach();
    healthy.attach();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(failed.status, TerminalSessionStatus.failed);
    expect(healthy.status, TerminalSessionStatus.running);
    expect(healthy.terminal.buffer.getText(), contains('healthy'));
    failed.dispose();
    healthy.dispose();
    await tester.pump();
  });
}
