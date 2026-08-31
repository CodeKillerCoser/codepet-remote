import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../security/pinned_tls.dart';
import 'models.dart';
import 'transport.dart';

class PinnedWebSocketGatewayTransport implements GatewayTransport {
  PinnedWebSocketGatewayTransport({required this.gatewayUri, required this.credential, required this.certSha256});
  final Uri gatewayUri;
  final String credential;
  final String certSha256;
  final StreamController<JsonMap> _events = StreamController<JsonMap>.broadcast();
  final Map<String, Completer<JsonMap>> _pending = {};
  WebSocket? _socket;
  HttpClient? _httpClient;
  int _nextId = 1;
  bool _closing = false;

  @override Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    if (gatewayUri.scheme != 'wss') {
      throw const GatewayConnectionException(
        'Gateway WebSocket URI must use wss',
      );
    }
    _closing = false;
    final context = SecurityContext(withTrustedRoots: false);
    final client = HttpClient(context: context);
    client.badCertificateCallback = (certificate, host, port) => constantTimeEquals(certificateSha256(certificate), certSha256);
    _httpClient = client;
    final socket = await WebSocket.connect(
      gatewayUri.toString(),
      headers: {'Authorization': 'Bearer $credential'},
      customClient: client,
    );
    _socket = socket;
    socket.listen(_handleFrame, onError: _handleError, onDone: _handleDone);
  }

  @override
  Future<JsonMap> request(String method, JsonMap params) {
    final socket = _socket;
    if (socket == null) throw const GatewayConnectionException('Gateway socket is not connected');
    final id = 'remote-${_nextId++}';
    final completer = Completer<JsonMap>();
    _pending[id] = completer;
    socket.add(jsonEncode({'protocolVersion': 1, 'id': id, 'method': method, 'params': params}));
    return completer.future.timeout(const Duration(seconds: 15), onTimeout: () { _pending.remove(id); throw GatewayConnectionException('$method request timed out'); });
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
    } catch (error, stack) { _events.addError(error, stack); }
  }

  void _handleError(Object error, StackTrace stack) { _fail(error); _events.addError(error, stack); }
  void _handleDone() {
    _socket = null;
    const error = GatewayConnectionException('Gateway connection closed');
    _fail(error);
    if (!_closing && !_events.isClosed) _events.addError(error);
  }
  void _fail(Object error) { final pending = _pending.values.toList(); _pending.clear(); for (final item in pending) { if (!item.isCompleted) item.completeError(error); } }

  @override
  Future<void> close() async {
    _closing = true;
    _fail(const GatewayConnectionException('Gateway connection closed'));
    await _socket?.close();
    _socket = null;
    _httpClient?.close(force: true);
    _httpClient = null;
    await _events.close();
  }
}
