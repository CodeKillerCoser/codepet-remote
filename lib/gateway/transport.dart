import 'dart:async';
import 'dart:io';

import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import 'models.dart';

/// Channel-only contract used by the generated Gateway client.
///
/// Implementations move JSON-RPC envelopes and surface server notifications;
/// they do not know Gateway methods or business DTOs.
abstract interface class GatewayTransport implements sdk.ProtocolTransport {
  Stream<JsonMap> get events;

  Future<void> connect();

  @override
  Future<Object?> request(Map<String, Object?> request);

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
  const GatewayConnectionException(
    this.message, {
    this.retryable = false,
    this.outcomeUnknown = false,
  });

  final String message;
  final bool retryable;
  final bool outcomeUnknown;

  @override
  String toString() => message;
}

bool isRetryableGatewayFailure(Object error) {
  if (error is GatewayConnectionException) return error.retryable;
  if (error is GatewayProtocolException) return error.retryable;
  if (error is TimeoutException || error is SocketException) return true;
  if (error is WebSocketException) {
    final status = error.httpStatusCode;
    return status == null || status == 408 || status == 429 || status >= 500;
  }
  return false;
}

bool isGatewayOutcomeUnknown(Object error) =>
    (error is GatewayConnectionException && error.outcomeUnknown) ||
    error is TimeoutException ||
    error is SocketException ||
    error is WebSocketException;
