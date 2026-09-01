/// Transport-only public surface for Gateway connectivity.
///
/// Discovery, TLS pinning and WebSocket delivery live below this boundary;
/// Gateway business methods are generated in `codepet_gateway_sdk`.
library;

export '../discovery/codepet_discovery.dart';
export '../discovery/resolving_gateway_transport.dart';
export '../gateway/pinned_web_socket_transport.dart';
export '../gateway/transport.dart';
export '../gateway/web_socket_transport.dart';
