import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:codepet_remote/application/ports/terminal_gateway.dart';

class TestTerminalGateway implements TerminalGateway {
  bool supported = true;
  int opens = 0;
  int reads = 0;
  int closes = 0;
  final keys = <String>[];
  final inputs = <(int, Uint8List)>[];
  final sizes = <(int, int)>[];
  final chunks = Queue<Uint8List>();
  Completer<void>? writeGate;
  Completer<RemoteTerminalOutput>? readGate;
  Object? readError;
  Object? writeError;
  int offset = 0;
  bool exited = false;

  void emit(String text) => chunks.add(Uint8List.fromList(utf8.encode(text)));
  @override
  Future<bool> isSupported() async => supported;
  @override
  Future<RemoteTerminalInfo> open({
    required String sessionKey,
    String? cwd,
    required int columns,
    required int rows,
  }) async {
    opens++;
    keys.add(sessionKey);
    return RemoteTerminalInfo(
      id: 'terminal-$opens',
      cwd: cwd ?? '/work/project',
      shell: '/bin/zsh',
      exited: false,
    );
  }

  @override
  Future<RemoteTerminalOutput> read(String id, int offset) async {
    reads++;
    if (readGate case final gate?) return gate.future;
    if (readError case final failure?) throw failure;
    if (offset == 0 && opens > 1) this.offset = 0;
    if (offset != this.offset) {
      throw StateError('unexpected offset $offset/${this.offset}');
    }
    final bytes = chunks.isEmpty ? Uint8List(0) : chunks.removeFirst();
    this.offset += bytes.length;
    return RemoteTerminalOutput(
      bytes: bytes,
      nextOffset: this.offset,
      exited: exited,
    );
  }

  @override
  Future<void> write(String id, int sequence, Uint8List bytes) async {
    inputs.add((sequence, Uint8List.fromList(bytes)));
    if (writeGate case final gate?) await gate.future;
    if (writeError case final failure?) throw failure;
  }

  @override
  Future<void> resize(String id, int columns, int rows) async =>
      sizes.add((columns, rows));
  @override
  Future<void> close(String id) async {
    closes++;
  }
}
