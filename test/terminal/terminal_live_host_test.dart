import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;
import 'package:codepet_remote/application/terminal/terminal_session_controller.dart';
import 'package:codepet_remote/gateway/terminal_gateway.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build codepet-host-terminal-probe from the Host checkout, then point this test
/// at that binary. Uses actual generated Dart/Rust Gateway RPC and a real PTY.
void main() {
  final binary = Platform.environment['CODEPET_TERMINAL_PROBE'];
  test(
    'Remote generated SDK and VT model consume a real Host PTY unchanged',
    () async {
      final process = await Process.start(binary!, const []);
      final transport = _ProbeTransport(process);
      var counter = 0;
      final protocol = sdk.ProtocolClient(
        transport,
        requestIdFactory: () => 'live-${counter++}',
      );
      final gateway = ProtocolTerminalGateway(
        protocol,
        <T>(operation) => operation(),
      );
      final controller = TerminalSessionController(
        gateway: () => gateway,
        pollDelay: const Duration(milliseconds: 10),
      );
      try {
        controller.attach();
        await _until(() => controller.canInput);
        controller.resize(92, 31);
        await Future<void>.delayed(const Duration(milliseconds: 180));
        controller.send("printf '\\033[32m电脑原始输出\\033[0m\\r\\n'; stty size\r");
        await _until(
          () => controller.terminal.buffer.getText().contains('31 92'),
        );
        final raw = utf8.decode(
          transport.output.toBytes(),
          allowMalformed: true,
        );
        expect(raw, contains('\x1b[32m电脑原始输出\x1b[0m'));
        expect(controller.terminal.buffer.getText(), contains('电脑原始输出'));
        expect(controller.terminal.buffer.getText(), isNot(contains('\uFFFD')));
        expect(controller.status, TerminalSessionStatus.running);
        final session = controller.info!.id;
        final emulator = controller.terminal;
        controller.detach();
        controller.attach();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(controller.info!.id, session);
        expect(controller.terminal, same(emulator));
        controller.send('exit\r');
        await _until(() => controller.status == TerminalSessionStatus.exited);
        await controller.end();
        expect(controller.info, isNull);
      } finally {
        controller.dispose();
        await transport.close();
      }
    },
    skip: binary == null
        ? 'Set CODEPET_TERMINAL_PROBE to the built Host test fixture'
        : false,
  );
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Live Host terminal condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

class _ProbeTransport implements sdk.ProtocolTransport {
  _ProbeTransport(this.process) {
    _stderr = process.stderr
        .transform(utf8.decoder)
        .listen((line) => errors.write(line));
    _stdout = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final response = jsonDecode(line) as Map<String, dynamic>;
            final result = response['result'];
            if (result is Map && result['data'] is String) {
              output.add(base64Decode(result['data'] as String));
            }
            _pending.remove(response['id'])?.complete(response);
          },
          onDone: () {
            for (final pending in _pending.values) {
              pending.completeError(StateError('Host probe ended: $errors'));
            }
            _pending.clear();
          },
        );
  }
  final Process process;
  final errors = StringBuffer();
  final output = BytesBuilder();
  final _pending = <Object?, Completer<Object?>>{};
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;
  @override
  Future<Object?> request(Map<String, Object?> request) {
    final response = Completer<Object?>();
    _pending[request['id']] = response;
    process.stdin.writeln(jsonEncode(request));
    return response.future;
  }

  Future<void> close() async {
    await process.stdin.close();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill();
    }
    await _stdout.cancel();
    await _stderr.cancel();
  }
}
