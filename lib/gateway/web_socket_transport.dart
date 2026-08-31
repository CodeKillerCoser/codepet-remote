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
  int _nextRequestId = 1;

  @override
  Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (_socket != null) {
      return;
    }
    if (connection.gatewayUri.scheme != 'wss') {
      throw const GatewayConnectionException(
        'v1 仅允许使用 wss:// 安全连接。',
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
  Future<JsonMap> request(String method, JsonMap params) {
    final socket = _socket;
    if (socket == null) {
      throw const GatewayConnectionException('尚未连接 Gateway。');
    }

    final requestId = 'remote-${_nextRequestId++}';
    final completer = Completer<JsonMap>();
    final timeout = Timer(requestTimeout, () {
      final pending = _pending.remove(requestId);
      pending?.completer.completeError(
        GatewayConnectionException('$method 请求超时。'),
      );
    });
    _pending[requestId] = _PendingRequest(
      completer: completer,
      timeout: timeout,
    );

    socket.add(
      jsonEncode({
        'protocolVersion': gatewayProtocolVersion,
        'id': requestId,
        'method': method,
        'params': params,
      }),
    );
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

      if (message['event'] is String && message['eventSequence'] is int) {
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

      final responseValue = message['response'];
      if (responseValue is! Map) {
        pending.completer.completeError(
          const GatewayConnectionException('Gateway 响应格式无效。'),
        );
        return;
      }
      final response = Map<String, dynamic>.from(responseValue);
      if (response['status'] == 'ok') {
        final result = response['result'];
        if (result is Map) {
          pending.completer.complete(Map<String, dynamic>.from(result));
        } else {
          pending.completer.completeError(
            const GatewayConnectionException('Gateway 响应缺少 result。'),
          );
        }
        return;
      }

      final error = response['error'];
      pending.completer.completeError(
        error is Map
            ? GatewayProtocolException.fromJson(
                Map<String, dynamic>.from(error),
              )
            : const GatewayConnectionException('Gateway 请求失败。'),
      );
    } catch (error, stackTrace) {
      _events.addError(error, stackTrace);
    }
  }

  void _handleSocketError(Object error, StackTrace stackTrace) {
    _failPending(GatewayConnectionException('Gateway 连接异常：$error'));
    _events.addError(error, stackTrace);
  }

  void _handleSocketDone() {
    _socket = null;
    _failPending(const GatewayConnectionException('Gateway 连接已关闭。'));
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
    _failPending(const GatewayConnectionException('Gateway 连接已关闭。'));
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

  final Completer<JsonMap> completer;
  final Timer timeout;
}
