import 'dart:async';

import '../gateway/models.dart';
import '../gateway/pinned_web_socket_transport.dart';
import '../gateway/transport.dart';
import 'codepet_discovery.dart';

abstract interface class EndpointAwareGatewayTransport {
  Uri? get selectedGatewayUri;
}

class ResolvingPinnedGatewayTransport
    implements GatewayTransport, EndpointAwareGatewayTransport {
  ResolvingPinnedGatewayTransport({
    required this.deviceId,
    required this.preferredGatewayUri,
    required this.credential,
    required this.certSha256,
    CodePetDiscovery? discovery,
    GatewayTransport Function(Uri gatewayUri, String credential, String certSha256)? transportFactory,
  })  : discovery = discovery ?? CodePetDiscovery(),
        transportFactory = transportFactory ?? _pinnedTransport;

  final String deviceId;
  final Uri preferredGatewayUri;
  final String credential;
  final String certSha256;
  final CodePetDiscovery discovery;
  final GatewayTransport Function(Uri gatewayUri, String credential, String certSha256) transportFactory;
  final StreamController<JsonMap> _events = StreamController<JsonMap>.broadcast();
  GatewayTransport? _active;
  StreamSubscription<JsonMap>? _activeEvents;

  @override
  Uri? selectedGatewayUri;

  @override
  Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    Object? preferredError;
    try {
      await _tryCandidate(preferredGatewayUri);
      return;
    } catch (error) {
      preferredError = error;
    }
    Object? discoveryError;
    try {
      await for (final host in discovery.discover()) {
        if (!isTrustedDiscoveryCandidate(host, deviceId)) continue;
        final candidate = preferredGatewayUri.replace(host: host.host, port: host.port);
        try {
          await _tryCandidate(candidate);
          return;
        } catch (error) {
          discoveryError = error;
        }
      }
    } catch (error) {
      discoveryError = error;
    }
    throw GatewayConnectionException(
      'Preferred endpoint failed and no trusted mDNS candidate connected. '
      'Preferred: $preferredError; discovery: $discoveryError',
      retryable: [preferredError, discoveryError]
          .whereType<Object>()
          .every(isRetryableGatewayFailure),
    );
  }

  Future<void> _tryCandidate(Uri gatewayUri) async {
    if (gatewayUri.scheme != 'wss') {
      throw const GatewayConnectionException('Resolved Gateway URI must use wss');
    }
    final transport = transportFactory(gatewayUri, credential, certSha256);
    try {
      await transport.connect();
      final subscription = transport.events.listen(
        _events.add,
        onError: _events.addError,
      );
      _active = transport;
      _activeEvents = subscription;
      selectedGatewayUri = gatewayUri;
    } catch (_) {
      try {
        await transport.close();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<JsonMap> request(String method, JsonMap params) {
    final active = _active;
    if (active == null) {
      throw const GatewayConnectionException(
        'Gateway endpoint is not connected',
        retryable: true,
      );
    }
    return active.request(method, params);
  }

  @override
  Future<void> close() async {
    await _activeEvents?.cancel();
    _activeEvents = null;
    await _active?.close();
    _active = null;
    await _events.close();
  }
}

GatewayTransport _pinnedTransport(
  Uri gatewayUri,
  String credential,
  String certSha256,
) => PinnedWebSocketGatewayTransport(
      gatewayUri: gatewayUri,
      credential: credential,
      certSha256: certSha256,
    );

bool isTrustedDiscoveryCandidate(
  DiscoveredCodePetHost host,
  String trustedDeviceId,
) {
  const exactKeys = {'id', 'name', 'vmin', 'vmax', 'pair'};
  if (host.txt.keys.toSet().difference(exactKeys).isNotEmpty ||
      host.txt.length != exactKeys.length ||
      host.txt['id'] != trustedDeviceId) {
    return false;
  }
  final minimum = int.tryParse(host.txt['vmin'] ?? '');
  final maximum = int.tryParse(host.txt['vmax'] ?? '');
  return minimum != null && maximum != null && minimum <= 1 && maximum >= 1;
}
