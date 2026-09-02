import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/domain/models.dart';
import '../core/errors/gateway_failures.dart';
import '../security/pinned_tls.dart';
import 'transport.dart';

class PinnedWebSocketGatewayTransport implements GatewayTransport {
  PinnedWebSocketGatewayTransport({
    required this.gatewayUri,
    required this.credential,
    required this.certSha256,
    this.connectTimeout = const Duration(seconds: 8),
    this.keepAliveInterval = const Duration(seconds: 20),
  });
  final Uri gatewayUri;
  final String credential;
  final String certSha256;
  final Duration connectTimeout;
  final Duration keepAliveInterval;
  final StreamController<JsonMap> _events = StreamController<JsonMap>.broadcast();
  final Map<String, Completer<Object?>> _pending = {};
  WebSocket? _socket;
  HttpClient? _httpClient;
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
      // Mobile networks, VPNs and NAT gateways commonly reap an otherwise
      // healthy idle WebSocket. Dart does not send protocol pings unless this
      // interval is configured, so keep the single Gateway channel active.
      socket.pingInterval = keepAliveInterval;
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
  Future<Object?> request(Map<String, Object?> request) {
    final socket = _socket;
    if (socket == null) {
      throw const GatewayConnectionException(
        'Gateway socket is not connected',
        retryable: true,
      );
    }
    final id = request['id'];
    final method = request['method'];
    if (id is! String || id.isEmpty || method is! String || method.isEmpty) {
      throw const FormatException('Generated Gateway request envelope is invalid');
    }
    final completer = Completer<Object?>();
    _pending[id] = completer;
    socket.add(jsonEncode(request));
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
      if (json['jsonrpc'] != '2.0') throw const FormatException('Unexpected JSON-RPC version');
      if (json['method'] is String && !json.containsKey('id')) { _events.add(json); return; }
      final id = json['id'];
      if (id is! String) throw const FormatException('Invalid Gateway response envelope');
      final pending = _pending.remove(id);
      if (pending == null) return;
      pending.complete(json);
    } catch (error, stack) {
      if (!_events.isClosed) _events.addError(error, stack);
    }
  }

  void _handleError(Object error, StackTrace stack) {
    _fail(error);
    if (!_closing && !_events.isClosed) _events.addError(error, stack);
  }
  void _handleDone() {
    final socket = _socket;
    final closeCode = socket?.closeCode;
    final closeReason = socket?.closeReason;
    _socket = null;
    final error = GatewayConnectionException(
      'Gateway connection closed '
      '(code: ${closeCode ?? 'unknown'}, '
      'reason: ${closeReason ?? 'none'})',
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
