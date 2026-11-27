import 'dart:typed_data';

class RemoteTerminalInfo {
  const RemoteTerminalInfo({
    required this.id,
    required this.cwd,
    required this.shell,
    required this.exited,
  });
  final String id;
  final String cwd;
  final String shell;
  final bool exited;
}

class RemoteTerminalOutput {
  const RemoteTerminalOutput({
    required this.bytes,
    required this.nextOffset,
    required this.exited,
  });
  final Uint8List bytes;
  final int nextOffset;
  final bool exited;
}

abstract interface class TerminalGatewayHost {
  TerminalGateway get terminalGateway;
}

/// Terminal operations belong to the Host, independently of AI Providers.
abstract interface class TerminalGateway {
  Future<bool> isSupported();
  Future<RemoteTerminalInfo> open({
    required String sessionKey,
    String? cwd,
    required int columns,
    required int rows,
  });
  Future<RemoteTerminalOutput> read(String id, int offset);
  Future<void> write(String id, int sequence, Uint8List bytes);
  Future<void> resize(String id, int columns, int rows);
  Future<void> close(String id);
}
