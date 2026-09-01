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
  static const stableGatewayPort = 47622;
  static const defaultConnectTimeout = Duration(seconds: 8);

  ResolvingPinnedGatewayTransport({
    required this.deviceId,
    required this.preferredGatewayUri,
    required this.credential,
    required this.certSha256,
    this.connectTimeout = defaultConnectTimeout,
    CodePetDiscovery? discovery,
    GatewayTransport Function(Uri gatewayUri, String credential, String certSha256)? transportFactory,
  })  : discovery = discovery ?? CodePetDiscovery(),
        transportFactory = transportFactory ??
            ((gatewayUri, credential, certSha256) => _pinnedTransport(
                  gatewayUri,
                  credential,
                  certSha256,
                  connectTimeout,
                ));

  final String deviceId;
  final Uri preferredGatewayUri;
  final String credential;
  final String certSha256;
  final Duration connectTimeout;
  final CodePetDiscovery discovery;
  final GatewayTransport Function(Uri gatewayUri, String credential, String certSha256) transportFactory;
  final StreamController<JsonMap> _events = StreamController<JsonMap>.broadcast();
  GatewayTransport? _active;
  GatewayTransport? _connectingCandidate;
  StreamSubscription<JsonMap>? _activeEvents;
  Future<void>? _closeFuture;
  bool _closed = false;

  @override
  Uri? selectedGatewayUri;

  @override
  Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    _throwIfClosed();
    final attempted = <Uri>{preferredGatewayUri};
    Object? preferredError;
    try {
      await _tryCandidate(preferredGatewayUri);
      return;
    } catch (error) {
      preferredError = error;
    }
    _throwIfClosed();
    Object? stableError;
    final stableCandidate = preferredGatewayUri.replace(
      port: stableGatewayPort,
    );
    if (attempted.add(stableCandidate)) {
      try {
        await _tryCandidate(stableCandidate);
        return;
      } catch (error) {
        stableError = error;
      }
    }
    _throwIfClosed();
    Object? discoveryError;
    try {
      await for (final host in discovery.discover()) {
        _throwIfClosed();
        if (!isTrustedDiscoveryCandidate(host, deviceId)) continue;
        final candidate = preferredGatewayUri.replace(host: host.host, port: host.port);
        if (!attempted.add(candidate)) continue;
        try {
          await _tryCandidate(candidate);
          return;
        } catch (error) {
          discoveryError = error;
        }
      }
    } catch (error) {
      if (_closed) rethrow;
      discoveryError = error;
    }
    throw GatewayConnectionException(
      'Preferred endpoint, stable port, and trusted mDNS candidates failed. '
      'Preferred: $preferredError; stable: $stableError; '
      'discovery: $discoveryError',
      retryable: [preferredError, stableError, discoveryError]
          .whereType<Object>()
          .every(isRetryableGatewayFailure),
    );
  }

  Future<void> _tryCandidate(Uri gatewayUri) async {
    _throwIfClosed();
    if (gatewayUri.scheme != 'wss') {
      throw const GatewayConnectionException('Resolved Gateway URI must use wss');
    }
    final transport = transportFactory(gatewayUri, credential, certSha256);
    _connectingCandidate = transport;
    try {
      await transport.connect().timeout(
        connectTimeout,
        onTimeout: () => throw GatewayConnectionException(
          'Gateway candidate ${gatewayUri.host}:${gatewayUri.port} connect '
          'timed out after ${connectTimeout.inMilliseconds}ms',
          retryable: true,
        ),
      );
      if (_closed || !identical(_connectingCandidate, transport)) {
        throw const GatewayConnectionException(
          'Gateway resolver closed while connecting',
          retryable: true,
        );
      }
      final subscription = transport.events.listen(
        _events.add,
        onError: _events.addError,
      );
      _connectingCandidate = null;
      _active = transport;
      _activeEvents = subscription;
      selectedGatewayUri = gatewayUri;
    } on TimeoutException {
      if (identical(_connectingCandidate, transport)) {
        _connectingCandidate = null;
        await _closeTransport(transport);
      }
      throw GatewayConnectionException(
        'Gateway candidate ${gatewayUri.host}:${gatewayUri.port} connect '
        'timed out after ${connectTimeout.inMilliseconds}ms',
        retryable: true,
      );
    } catch (_) {
      if (identical(_connectingCandidate, transport)) {
        _connectingCandidate = null;
        await _closeTransport(transport);
      }
      rethrow;
    }
  }

  void _throwIfClosed() {
    if (_closed) {
      throw const GatewayConnectionException(
        'Gateway resolver is closed',
        retryable: true,
      );
    }
  }

  Future<void> _closeTransport(GatewayTransport transport) async {
    try {
      await transport.close().timeout(connectTimeout);
    } catch (_) {}
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
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final connectingCandidate = _connectingCandidate;
    _connectingCandidate = null;
    final active = _active;
    _active = null;
    await _activeEvents?.cancel();
    _activeEvents = null;
    if (connectingCandidate != null) {
      await _closeTransport(connectingCandidate);
    }
    if (active != null && !identical(active, connectingCandidate)) {
      await _closeTransport(active);
    }
    if (!_events.isClosed) await _events.close();
  }
}

GatewayTransport _pinnedTransport(
  Uri gatewayUri,
  String credential,
  String certSha256,
  Duration connectTimeout,
) => PinnedWebSocketGatewayTransport(
      gatewayUri: gatewayUri,
      credential: credential,
      certSha256: certSha256,
      connectTimeout: connectTimeout,
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
