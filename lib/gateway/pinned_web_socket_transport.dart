import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/domain/models.dart';
import '../application/errors/application_failures.dart';
import '../security/pinned_tls.dart';
import '../diagnostics/app_log.dart';
import 'transport.dart';

final AppLog _log = AppLog.named('gateway.websocket');

class PinnedWebSocketGatewayTransport implements GatewayTransport {
  static const compressionOptions = CompressionOptions(
    clientNoContextTakeover: true,
    serverNoContextTakeover: true,
  );

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
    _log.info(
      'Opening Gateway WebSocket to ${gatewayUri.host}:${gatewayUri.port}',
    );
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context);
    client.connectionTimeout = connectTimeout;
    client.badCertificateCallback = (certificate, host, port) {
      final matches = constantTimeEquals(
        certificateSha256(certificate),
        certSha256,
      );
      if (!matches) {
        _log.warning('Gateway TLS pin rejected certificate from $host:$port');
      }
      return matches;
    };
    _httpClient = client;
    final connection = WebSocket.connect(
      gatewayUri.toString(),
      headers: {'Authorization': 'Bearer $credential'},
      customClient: client,
      compression: compressionOptions,
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
      _log.info(
        'Gateway WebSocket connected to ${gatewayUri.host}:${gatewayUri.port}',
      );
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
    } on WebSocketException catch (error) {
      if (identical(_httpClient, client)) _httpClient = null;
      client.close(force: true);
      throw GatewayConnectionException(
        'Gateway WebSocket upgrade failed: $error',
        retryable: _isRetryableWebSocketException(error),
      );
    } catch (error, stackTrace) {
      if (identical(_httpClient, client)) _httpClient = null;
      client.close(force: true);
      _log.warning(
        'Gateway WebSocket connection failed for '
        '${gatewayUri.host}:${gatewayUri.port}',
        error: error,
        stackTrace: stackTrace,
      );
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
  Future<Object?> request(Map<String, Object?> request) async {
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
    final stopwatch = Stopwatch()..start();
    try {
      socket.add(jsonEncode(request));
      final response = await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          throw GatewayConnectionException(
            '$method request timed out',
            retryable: true,
            outcomeUnknown: true,
          );
        },
      );
      _log.fine(
        'Gateway RPC completed method=$method requestId=$id '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
      );
      return response;
    } catch (error, stackTrace) {
      _pending.remove(id);
      _log.warning(
        'Gateway RPC failed method=$method requestId=$id '
        'elapsedMs=${stopwatch.elapsedMilliseconds}',
        error: error,
        stackTrace: stackTrace,
      );
      rethrow;
    }
  }

  void _handleFrame(dynamic frame) {
    try {
      if (frame is! String) throw const FormatException('Gateway requires text frames');
      final decoded = jsonDecode(frame);
      if (decoded is! Map) throw const FormatException('Gateway envelope must be an object');
      final json = Map<String, dynamic>.from(decoded);
      if (json['jsonrpc'] != '2.0') throw const FormatException('Unexpected JSON-RPC version');
      if (json['method'] is String && !json.containsKey('id')) {
        _events.add(json);
        return;
      }
      final id = json['id'];
      if (id is! String) throw const FormatException('Invalid Gateway response envelope');
      final pending = _pending.remove(id);
      if (pending == null) {
        _log.fine('Ignoring unmatched Gateway response requestId=$id');
        return;
      }
      pending.complete(json);
    } catch (error, stack) {
      _log.warning(
        'Gateway frame rejected at transport boundary',
        error: error,
        stackTrace: stack,
      );
      if (!_events.isClosed) _events.addError(error, stack);
    }
  }

  void _handleError(Object error, StackTrace stack) {
    final failure = _connectionFailure(error);
    _log.warning(
      'Gateway WebSocket stream failed for ${gatewayUri.host}:${gatewayUri.port}',
      error: failure,
      stackTrace: stack,
    );
    _fail(failure);
    if (!_closing && !_events.isClosed) _events.addError(failure, stack);
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
    _log.warning(
      'Gateway WebSocket closed for ${gatewayUri.host}:${gatewayUri.port} '
      '(code=${closeCode ?? 'unknown'})',
      error: error,
    );
    _fail(error);
    if (!_closing && !_events.isClosed) _events.addError(error);
  }
  void _fail(Object error) { final pending = _pending.values.toList(); _pending.clear(); for (final item in pending) { if (!item.isCompleted) item.completeError(error); } }

  @override
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _log.info(
      'Closing Gateway WebSocket for ${gatewayUri.host}:${gatewayUri.port}',
    );
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
    closeCode == WebSocketStatus.goingAway ||
    closeCode == WebSocketStatus.abnormalClosure ||
    closeCode == 1011 ||
    closeCode == 1012 ||
    closeCode == 1013;

bool _isRetryableWebSocketException(WebSocketException error) {
  final status = error.httpStatusCode;
  return status == null || status == 408 || status == 429 || status >= 500;
}

GatewayConnectionException _connectionFailure(Object error) {
  if (error is GatewayConnectionException) return error;
  if (error is WebSocketException) {
    return GatewayConnectionException(
      'Gateway WebSocket failed: $error',
      retryable: _isRetryableWebSocketException(error),
      outcomeUnknown: true,
    );
  }
  if (error is SocketException || error is TimeoutException) {
    return GatewayConnectionException(
      'Gateway connection failed: $error',
      retryable: true,
      outcomeUnknown: true,
    );
  }
  return GatewayConnectionException(
    'Gateway connection failed: $error',
    outcomeUnknown: true,
  );
}
