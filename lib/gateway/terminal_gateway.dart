import 'dart:convert';
import 'dart:typed_data';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../application/ports/terminal_gateway.dart';

/// Uses generated typed methods; the channel carries ordinary Gateway RPCs.
typedef TerminalProtocolCall = Future<T> Function<T>(Future<T> Function());

final class ProtocolTerminalGateway implements TerminalGateway {
  ProtocolTerminalGateway(this.protocol, this.call);
  final sdk.ProtocolClient protocol;
  final TerminalProtocolCall call;

  @override
  Future<bool> isSupported() async => (await call(
    () => protocol.protocolDescribe(sdk.ProtocolDescribeRequest()),
  )).features.contains(sdk.ProtocolFeature.terminalPtyV1);

  @override
  Future<RemoteTerminalInfo> open({
    required String sessionKey,
    String? cwd,
    required int columns,
    required int rows,
  }) async {
    final response = await call(
      () => protocol.terminalOpen(
        sdk.TerminalOpenRequest(
          sessionKey: sessionKey,
          cwd: cwd,
          columns: columns,
          rows: rows,
        ),
      ),
    );
    final session = response.session;
    return RemoteTerminalInfo(
      id: session.terminalId,
      cwd: session.cwd,
      shell: session.shell,
      exited: session.exited,
    );
  }

  @override
  Future<RemoteTerminalOutput> read(String id, int offset) async {
    final response = await call(
      () => protocol.terminalRead(
        sdk.TerminalReadRequest(terminalId: id, offset: offset),
      ),
    );
    return RemoteTerminalOutput(
      bytes: base64Decode(response.data),
      nextOffset: response.nextOffset,
      exited: response.exited,
    );
  }

  @override
  Future<void> write(String id, int sequence, Uint8List bytes) async {
    await call(
      () => protocol.terminalWrite(
        sdk.TerminalWriteRequest(
          terminalId: id,
          sequence: sequence,
          data: base64Encode(bytes),
        ),
      ),
    );
  }

  @override
  Future<void> resize(String id, int columns, int rows) async {
    await call(
      () => protocol.terminalResize(
        sdk.TerminalResizeRequest(terminalId: id, columns: columns, rows: rows),
      ),
    );
  }

  @override
  Future<void> close(String id) async {
    await call(
      () => protocol.terminalClose(sdk.TerminalCloseRequest(terminalId: id)),
    );
  }
}
