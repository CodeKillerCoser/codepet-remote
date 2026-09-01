import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../security/pinned_tls.dart';
import 'models.dart';
import 'transport.dart';

class PinnedWebSocketGatewayTransport implements GatewayTransport {
  PinnedWebSocketGatewayTransport({
    required this.gatewayUri,
    required this.credential,
    required this.certSha256,
    this.connectTimeout = const Duration(seconds: 8),
  });
  final Uri gatewayUri;
  final String credential;
  final String certSha256;
  final Duration connectTimeout;
  final StreamController<JsonMap> _events = StreamController<JsonMap>.broadcast();
  final Map<String, Completer<JsonMap>> _pending = {};
  WebSocket? _socket;
  HttpClient? _httpClient;
  int _nextId = 1;
  bool _closing = false;
  Future<void>? _closeFuture;

  @override Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (gatewayUri.scheme != 'wss') {
      throw const GatewayConnectionException(
        'Gateway WebSocket URI must use wss',
      );
    }
    if (_closing || _events.isClosed) {
      throw const GatewayConnectionException(
        'Gateway transport is closed',
        retryable: true,
      );
    }
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context);
    client.connectionTimeout = connectTimeout;
    client.badCertificateCallback = (certificate, host, port) => constantTimeEquals(certificateSha256(certificate), certSha256);
    _httpClient = client;
    final connection = WebSocket.connect(
      gatewayUri.toString(),
      headers: {'Authorization': 'Bearer $credential'},
      customClient: client,
    );
    try {
      final socket = await connection.timeout(
        connectTimeout,
        onTimeout: () {
          if (identical(_httpClient, client)) _httpClient = null;
          client.close(force: true);
          unawaited(_closeLateSocket(connection));
          throw GatewayConnectionException(
            'Gateway WebSocket connect timed out after '
            '${connectTimeout.inMilliseconds}ms',
            retryable: true,
          );
        },
      );
      if (_closing || !identical(_httpClient, client)) {
        client.close(force: true);
        await _closeSocket(socket);
        throw const GatewayConnectionException(
          'Gateway connection closed while connecting',
          retryable: true,
        );
      }
      _socket = socket;
      socket.listen(_handleFrame, onError: _handleError, onDone: _handleDone);
    } on TimeoutException {
      if (identical(_httpClient, client)) _httpClient = null;
      client.close(force: true);
      throw GatewayConnectionException(
        'Gateway WebSocket connect timed out after '
        '${connectTimeout.inMilliseconds}ms',
        retryable: true,
      );
    } on SocketException catch (error) {
      if (identical(_httpClient, client)) _httpClient = null;
      client.close(force: true);
      throw GatewayConnectionException(
        'Gateway WebSocket connection failed: ${error.message}',
        retryable: true,
      );
    } catch (_) {
      if (identical(_httpClient, client)) _httpClient = null;
      client.close(force: true);
      rethrow;
    }
  }

  Future<void> _closeLateSocket(Future<WebSocket> connection) async {
    try {
      await _closeSocket(await connection);
    } catch (_) {}
  }

  Future<void> _closeSocket(WebSocket socket) async {
    try {
      await socket.close().timeout(connectTimeout);
    } catch (_) {}
  }

  @override
  Future<JsonMap> request(String method, JsonMap params) {
    final socket = _socket;
    if (socket == null) {
      throw const GatewayConnectionException(
        'Gateway socket is not connected',
        retryable: true,
      );
    }
    final id = 'remote-${_nextId++}';
    final completer = Completer<JsonMap>();
    _pending[id] = completer;
    socket.add(jsonEncode({'protocolVersion': 1, 'id': id, 'method': method, 'params': params}));
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () {
      _pending.remove(id);
      throw GatewayConnectionException(
        '$method request timed out',
        retryable: true,
        outcomeUnknown: true,
      );
    });
  }

  void _handleFrame(dynamic frame) {
    try {
      if (frame is! String) throw const FormatException('Gateway requires text frames');
      final decoded = jsonDecode(frame);
      if (decoded is! Map) throw const FormatException('Gateway envelope must be an object');
      final json = Map<String, dynamic>.from(decoded);
      if (json['protocolVersion'] != 1) throw const FormatException('Unexpected Gateway protocol version');
      if (json['event'] is String) { _events.add(json); return; }
      final id = json['id'];
      final method = json['method'];
      if (id is! String || method is! String) throw const FormatException('Invalid Gateway response envelope');
      final pending = _pending.remove(id);
      if (pending == null) return;
      final response = json['response'];
      if (response is! Map) { pending.completeError(const FormatException('Missing Gateway response')); return; }
      final responseMap = Map<String, dynamic>.from(response);
      if (responseMap['status'] == 'ok' && responseMap['result'] is Map) {
        pending.complete(Map<String, dynamic>.from(responseMap['result'] as Map));
      } else {
        final error = responseMap['error'];
        pending.completeError(error is Map ? GatewayProtocolException.fromJson(Map<String, dynamic>.from(error)) : const GatewayConnectionException('Gateway request failed'));
      }
    } catch (error, stack) {
      if (!_events.isClosed) _events.addError(error, stack);
    }
  }

  void _handleError(Object error, StackTrace stack) {
    _fail(error);
    if (!_closing && !_events.isClosed) _events.addError(error, stack);
  }
  void _handleDone() {
    final closeCode = _socket?.closeCode;
    _socket = null;
    final error = GatewayConnectionException(
      'Gateway connection closed (code: ${closeCode ?? 'unknown'})',
      retryable: isRetryableWebSocketCloseCode(closeCode),
      outcomeUnknown: true,
    );
    _fail(error);
    if (!_closing && !_events.isClosed) _events.addError(error);
  }
  void _fail(Object error) { final pending = _pending.values.toList(); _pending.clear(); for (final item in pending) { if (!item.isCompleted) item.completeError(error); } }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    _fail(const GatewayConnectionException(
      'Gateway connection closed',
      retryable: false,
      outcomeUnknown: true,
    ));
    final client = _httpClient;
    _httpClient = null;
    client?.close(force: true);
    final socket = _socket;
    _socket = null;
    if (socket != null) await _closeSocket(socket);
    if (!_events.isClosed) await _events.close();
  }
}

bool isRetryableWebSocketCloseCode(int? closeCode) =>
    closeCode == WebSocketStatus.abnormalClosure;
