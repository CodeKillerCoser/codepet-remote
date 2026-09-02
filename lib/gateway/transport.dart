import 'dart:async';
import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../core/domain/models.dart';

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

/// Optional connection metadata exposed by endpoint-selecting transports.
abstract interface class EndpointAwareGatewayTransport {
  Uri? get selectedGatewayUri;
}

/// Controls whether a validated candidate may replace the persisted endpoint.
abstract interface class EndpointPersistenceAwareGatewayTransport {
  bool get shouldPersistSelectedGatewayUri;
}
