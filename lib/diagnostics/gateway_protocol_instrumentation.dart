import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../application/ports/trace_recorder.dart';

final class GatewayProtocolInstrumentation
    implements sdk.ProtocolClientInstrumentation {
  GatewayProtocolInstrumentation(this.recorder);

  final TraceRecorder recorder;
  bool wirePropagationEnabled = false;

  @override
  Future<T> traceRequest<T>({
    required sdk.ProtocolMethod method,
    required sdk.RequestId requestId,
    required Future<T> Function(sdk.TraceContext? traceContext) invoke,
  }) => recorder.trace(
        'gateway.rpc.client',
        (context) => invoke(
          !wirePropagationEnabled ||
                  method == sdk.ProtocolMethod.protocolHandshake ||
                  method == sdk.ProtocolMethod.protocolDescribe ||
                  context == null
              ? null
              : sdk.TraceContext(
                  traceparent: context.traceparent,
                  tracestate: context.traceState,
                ),
        ),
        attributes: {
          'rpc.method': method.toJson(),
          'rpc.requestId': requestId,
        },
      );
}
