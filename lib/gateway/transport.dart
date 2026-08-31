import 'models.dart';

abstract interface class GatewayTransport {
  Stream<JsonMap> get events;

  Future<void> connect();

  Future<JsonMap> request(String method, JsonMap params);

  Future<void> close();
}

class GatewayProtocolException implements Exception {
  const GatewayProtocolException({
    required this.code,
    required this.message,
    required this.retryable,
    this.details,
  });

  factory GatewayProtocolException.fromJson(JsonMap json) {
    return GatewayProtocolException(
      code: json['code'] is String ? json['code'] as String : 'protocol_error',
      message: json['message'] is String
          ? json['message'] as String
          : 'Gateway request failed',
      retryable: json['retryable'] == true,
      details: json['details'] is Map
          ? Map<String, dynamic>.from(json['details'] as Map)
          : null,
    );
  }

  final String code;
  final String message;
  final bool retryable;
  final JsonMap? details;

  @override
  String toString() => message;
}

class GatewayConnectionException implements Exception {
  const GatewayConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}
