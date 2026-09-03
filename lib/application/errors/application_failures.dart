import 'dart:async';

import '../../core/domain/models.dart';

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

class GatewayCursorGapException implements Exception {
  const GatewayCursorGapException(this.message);

  final String message;

  @override
  String toString() => message;
}

bool isRetryableGatewayFailure(Object error) =>
    error is GatewayConnectionException && error.retryable ||
    error is GatewayProtocolException && error.retryable ||
    error is TimeoutException;

bool isGatewayOutcomeUnknown(Object error) =>
    error is GatewayConnectionException && error.outcomeUnknown ||
    error is TimeoutException;
