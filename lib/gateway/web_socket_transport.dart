import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'models.dart';
import 'transport.dart';

class WebSocketGatewayTransport implements GatewayTransport {
  WebSocketGatewayTransport({
    required this.connection,
    this.connectTimeout = const Duration(seconds: 8),
    this.requestTimeout = const Duration(seconds: 15),
  });

  final DeviceConnection connection;
  final Duration connectTimeout;
  final Duration requestTimeout;

  final StreamController<JsonMap> _events =
      StreamController<JsonMap>.broadcast();
  final Map<String, _PendingRequest> _pending = {};
  WebSocket? _socket;
  StreamSubscription<dynamic>? _socketSubscription;

  @override
  Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (_socket != null) {
      return;
    }
    if (connection.gatewayUri.scheme != 'wss') {
      throw const GatewayConnectionException(
        'Gateway channel 仅允许使用 wss:// 安全连接。',
      );
    }

    try {
      final socket = await WebSocket.connect(
        connection.gatewayUri.toString(),
        headers: {
          'Authorization': 'Bearer ${connection.pairingToken}',
        },
      ).timeout(connectTimeout);
      _socket = socket;
      _socketSubscription = socket.listen(
        _handleFrame,
        onError: _handleSocketError,
        onDone: _handleSocketDone,
        cancelOnError: false,
      );
    } on TimeoutException {
      throw const GatewayConnectionException('连接 Gateway 超时。');
    } on WebSocketException catch (error) {
      throw GatewayConnectionException('无法连接 Gateway：${error.message}');
    } on SocketException catch (error) {
      throw GatewayConnectionException('无法连接 Gateway：${error.message}');
    }
  }

  @override
  Future<Object?> request(Map<String, Object?> request) {
    final socket = _socket;
    if (socket == null) {
      throw const GatewayConnectionException('尚未连接 Gateway。');
    }

    final requestId = request['id'];
    final method = request['method'];
    if (requestId is! String || requestId.isEmpty || method is! String) {
      throw const FormatException('Generated Gateway request envelope is invalid');
    }
    final completer = Completer<JsonMap>();
    final timeout = Timer(requestTimeout, () {
      final pending = _pending.remove(requestId);
      pending?.completer.completeError(
        GatewayConnectionException(
          '$method 请求超时。',
          outcomeUnknown: true,
        ),
      );
    });
    _pending[requestId] = _PendingRequest(
      completer: completer,
      timeout: timeout,
    );

    socket.add(jsonEncode(request));
    return completer.future;
  }

  void _handleFrame(dynamic frame) {
    try {
      final String text;
      if (frame is String) {
        text = frame;
      } else if (frame is List<int>) {
        text = utf8.decode(frame);
      } else {
        throw const FormatException('Unsupported WebSocket frame');
      }

      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('Gateway frame must be an object');
      }
      final message = Map<String, dynamic>.from(decoded);

      if (message['jsonrpc'] == '2.0' &&
          message['method'] is String &&
          !message.containsKey('id')) {
        _events.add(message);
        return;
      }

      final requestId = message['id'];
      if (requestId is! String) {
        throw const FormatException('Gateway response is missing id');
      }
      final pending = _pending.remove(requestId);
      if (pending == null) {
        return;
      }
      pending.timeout.cancel();

      pending.completer.complete(message);
    } catch (error, stackTrace) {
      _events.addError(error, stackTrace);
    }
  }

  void _handleSocketError(Object error, StackTrace stackTrace) {
    _failPending(GatewayConnectionException(
      'Gateway 连接异常：$error',
      outcomeUnknown: true,
    ));
    _events.addError(error, stackTrace);
  }

  void _handleSocketDone() {
    _socket = null;
    _failPending(const GatewayConnectionException(
      'Gateway 连接已关闭。',
      outcomeUnknown: true,
    ));
  }

  void _failPending(Object error) {
    final pendingRequests = _pending.values.toList(growable: false);
    _pending.clear();
    for (final pending in pendingRequests) {
      pending.timeout.cancel();
      if (!pending.completer.isCompleted) {
        pending.completer.completeError(error);
      }
    }
  }

  @override
  Future<void> close() async {
    _failPending(const GatewayConnectionException(
      'Gateway 连接已关闭。',
      outcomeUnknown: true,
    ));
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _socket?.close();
    _socket = null;
    await _events.close();
  }
}

class _PendingRequest {
  const _PendingRequest({
    required this.completer,
    required this.timeout,
  });

  final Completer<Object?> completer;
  final Timer timeout;
}
