import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:xterm/core.dart';

import '../errors/application_failures.dart';
import '../ports/terminal_gateway.dart';
import '../support/application_notifier.dart';
import 'terminal_input_handler.dart';

enum TerminalSessionStatus {
  idle,
  opening,
  running,
  offline,
  failed,
  exited,
  closing,
  unsupported,
}

/// Owns one Host PTY attachment and its pure-Dart VT model across sheet routes.
/// The device owns this controller; dismissing a sheet only stops polling.
class TerminalSessionController extends ApplicationNotifier {
  TerminalSessionController({
    required this.gateway,
    this.cwd,
    this.pollDelay = const Duration(milliseconds: 120),
    this.requestTimeout = const Duration(seconds: 5),
  }) {
    _resetEmulator();
  }

  final TerminalGateway? Function() gateway;
  final String? cwd;
  final Duration pollDelay;
  final Duration requestTimeout;
  late Terminal terminal;
  late ByteConversionSink _decoder;
  TerminalSessionStatus status = TerminalSessionStatus.idle;
  RemoteTerminalInfo? info;
  String? error;
  int columns = 80;
  int rows = 24;
  String _sessionKey = _newKey();
  int _offset = 0;
  int _sequence = 0;
  int _epoch = 0;
  int _attachments = 0;
  int _pendingInputBytes = 0;
  bool _reading = false;
  bool _opening = false;
  bool _disposed = false;
  bool _inputUncertain = false;
  bool _resizing = false;
  bool _resizeDirty = false;
  Timer? _pollTimer;
  Timer? _resizeTimer;
  Future<void> _writes = Future.value();

  bool get canInput =>
      status == TerminalSessionStatus.running && !_inputUncertain;
  bool get hasSession => info != null;

  static String _newKey() =>
      base64UrlEncode(List.generate(24, (_) => Random.secure().nextInt(256)));

  void _resetEmulator() {
    terminal = Terminal(
      maxLines: 10000,
      inputHandler: CascadeInputHandler([
        const TerminalCursorInputHandler(),
        defaultInputHandler,
      ]),
    );
    _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      StringConversionSink.from(_TerminalSink(terminal)),
    );
    terminal.onOutput = send;
    terminal.onResize = (width, height, _, _) => resize(width, height);
  }

  void attach() {
    _attachments++;
    if (info == null &&
        (status == TerminalSessionStatus.idle ||
            status == TerminalSessionStatus.unsupported ||
            status == TerminalSessionStatus.failed)) {
      unawaited(open());
    } else {
      _schedulePoll(Duration.zero);
    }
  }

  void detach() {
    _attachments = max(0, _attachments - 1);
    if (_attachments == 0) _pollTimer?.cancel();
  }

  Future<void> open() async {
    if (_disposed || _opening || info != null) return;
    _opening = true;
    final epoch = _epoch;
    _setStatus(TerminalSessionStatus.opening);
    try {
      final client = gateway();
      if (client == null) throw const GatewayConnectionException('电脑尚未连接');
      if (!await client.isSupported().timeout(requestTimeout)) {
        if (_current(epoch)) {
          _setStatus(
            TerminalSessionStatus.unsupported,
            '电脑端暂不支持终端，请更新 CodePet',
          );
        }
        return;
      }
      final result = await client
          .open(sessionKey: _sessionKey, cwd: cwd, columns: columns, rows: rows)
          .timeout(requestTimeout);
      if (!_current(epoch)) return;
      info = result;
      _setStatus(TerminalSessionStatus.running);
      // The view may have resized while open was in flight.
      resize(columns, rows);
      _schedulePoll(Duration.zero);
    } catch (failure) {
      if (_current(epoch)) {
        _setStatus(TerminalSessionStatus.failed, failure.toString());
      }
    } finally {
      if (_current(epoch)) _opening = false;
    }
  }

  Future<void> retry() async {
    if (info == null) return open();
    if (_inputUncertain) return;
    _setStatus(TerminalSessionStatus.running);
    _schedulePoll(Duration.zero);
  }

  void _schedulePoll(Duration delay) {
    _pollTimer?.cancel();
    if (_disposed ||
        _attachments == 0 ||
        info == null ||
        !(status == TerminalSessionStatus.running ||
            status == TerminalSessionStatus.offline)) {
      return;
    }
    _pollTimer = Timer(delay, () => unawaited(_poll()));
  }

  Future<void> _poll() async {
    if (_disposed || info == null) return;
    if (_reading) {
      _schedulePoll(pollDelay);
      return;
    }
    final client = gateway();
    if (client == null) {
      _setStatus(TerminalSessionStatus.offline, '电脑连接中断，等待重新连接');
      _schedulePoll(const Duration(milliseconds: 500));
      return;
    }
    _reading = true;
    final epoch = _epoch;
    var nextDelay = pollDelay;
    try {
      final output = await client
          .read(info!.id, _offset)
          .timeout(requestTimeout);
      if (!_current(epoch)) return;
      if (output.nextOffset != _offset + output.bytes.length) {
        throw const FormatException('终端输出偏移不连续');
      }
      if (!_inputUncertain) _setStatus(TerminalSessionStatus.running);
      _decoder.add(output.bytes);
      _offset = output.nextOffset;
      if (output.exited) {
        _decoder.close();
        _setStatus(TerminalSessionStatus.exited);
      } else if (!_inputUncertain) {
        _setStatus(TerminalSessionStatus.running);
      }
      if (_resizeDirty && canInput) unawaited(_resize());
      if (output.bytes.isNotEmpty) nextDelay = const Duration(milliseconds: 16);
    } catch (failure) {
      if (!_current(epoch)) return;
      if (failure is GatewayConnectionException ||
          failure is TimeoutException ||
          gateway() == null) {
        _setStatus(TerminalSessionStatus.offline, '终端连接暂时中断，正在重新连接');
        nextDelay = const Duration(milliseconds: 500);
      } else {
        _setStatus(TerminalSessionStatus.failed, failure.toString());
      }
    } finally {
      _reading = false;
      if (_current(epoch)) _schedulePoll(nextDelay);
    }
  }

  void send(String text) {
    if (!canInput || text.isEmpty) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    if (_pendingInputBytes + bytes.length > 64 * 1024) {
      _inputUncertain = true;
      _setStatus(TerminalSessionStatus.failed, '待发送输入过多，请新建终端后继续');
      return;
    }
    _pendingInputBytes += bytes.length;
    final epoch = _epoch;
    _writes = _writes.then((_) async {
      try {
        if (!_current(epoch) ||
            _inputUncertain ||
            status != TerminalSessionStatus.running) {
          return;
        }
        final client = gateway();
        if (client == null) throw const GatewayConnectionException('电脑尚未连接');
        for (var start = 0; start < bytes.length; start += 16 * 1024) {
          if (!_current(epoch) ||
              _inputUncertain ||
              status != TerminalSessionStatus.running) {
            return;
          }
          final chunk = Uint8List.sublistView(
            bytes,
            start,
            min(start + 16 * 1024, bytes.length),
          );
          await client
              .write(info!.id, ++_sequence, chunk)
              .timeout(requestTimeout);
        }
      } catch (_) {
        if (_current(epoch)) {
          _inputUncertain = true;
          _setStatus(TerminalSessionStatus.failed, '终端输入未确认，已停止发送；请新建终端后继续');
        }
      } finally {
        _pendingInputBytes -= bytes.length;
      }
    });
  }

  void resize(int width, int height) {
    columns = width.clamp(2, 500);
    rows = height.clamp(1, 300);
    _resizeDirty = true;
    _resizeTimer?.cancel();
    _resizeTimer = Timer(
      const Duration(milliseconds: 100),
      () => unawaited(_resize()),
    );
  }

  Future<void> _resize() async {
    if (_resizing || !_resizeDirty || info == null || !canInput) return;
    final client = gateway();
    if (client == null) return;
    _resizeDirty = false;
    _resizing = true;
    final epoch = _epoch;
    try {
      await client.resize(info!.id, columns, rows).timeout(requestTimeout);
    } catch (_) {
      if (_current(epoch)) _resizeDirty = true;
    } finally {
      _resizing = false;
      if (_current(epoch) && _resizeDirty) {
        _resizeTimer = Timer(
          const Duration(milliseconds: 500),
          () => unawaited(_resize()),
        );
      }
    }
  }

  Future<void> end() async {
    if (_disposed || status == TerminalSessionStatus.closing || _opening) {
      return;
    }
    final current = info;
    if (current == null) return;
    _setStatus(TerminalSessionStatus.closing);
    _pollTimer?.cancel();
    final epoch = ++_epoch;
    try {
      final client = gateway();
      if (client == null) {
        throw const GatewayConnectionException('请先连接电脑，再结束终端');
      }
      await client.close(current.id).timeout(requestTimeout);
      if (!_current(epoch)) return;
      info = null;
      _setStatus(TerminalSessionStatus.exited);
    } catch (failure) {
      if (_current(epoch)) {
        _setStatus(TerminalSessionStatus.failed, failure.toString());
      }
    }
  }

  Future<void> restart() async {
    if (_opening || status == TerminalSessionStatus.closing) return;
    if (info != null) await end();
    if (info != null || _disposed) return;
    _epoch++;
    _offset = 0;
    _sequence = 0;
    _sessionKey = _newKey();
    _inputUncertain = false;
    terminal.onOutput = null;
    terminal.onResize = null;
    _resetEmulator();
    await open();
  }

  bool _current(int epoch) => !_disposed && epoch == _epoch;
  void _setStatus(TerminalSessionStatus value, [String? message]) {
    if (_disposed || status == value && error == message) return;
    status = value;
    error = message;
    notifyApplicationListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _epoch++;
    _pollTimer?.cancel();
    _resizeTimer?.cancel();
    terminal.onOutput = null;
    terminal.onResize = null;
    super.dispose();
  }
}

class _TerminalSink implements Sink<String> {
  _TerminalSink(this.terminal);
  final Terminal terminal;
  @override
  void add(String data) => terminal.write(data);
  @override
  void close() {}
}
