import 'dart:async';
import 'dart:io';

import '../domain/models.dart';

class GatewayProtocolException implements Exception {
  const GatewayProtocolException({
    required this.code,
    required this.message,
    required this.retryable,
    this.details,
  });

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
