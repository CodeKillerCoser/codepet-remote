import 'dart:async';

import '../core/domain/models.dart';
import '../application/errors/application_failures.dart';
import '../gateway/pinned_web_socket_transport.dart';
import '../gateway/transport.dart';
import 'codepet_discovery.dart';

Uri? debugAndroidEmulatorGatewayCandidate(Uri preferredGatewayUri) {
  if (!preferredGatewayUri.hasScheme || preferredGatewayUri.host.isEmpty) {
    return null;
  }
  try {
    return preferredGatewayUri.replace(host: '10.0.2.2');
  } on FormatException {
    return null;
  }
}

class ResolvingPinnedGatewayTransport
    implements GatewayTransport, EndpointAwareGatewayTransport,
        EndpointPersistenceAwareGatewayTransport {
  static const stableGatewayPort = 47622;
  static const defaultConnectTimeout = Duration(seconds: 8);

  ResolvingPinnedGatewayTransport({
    required this.deviceId,
    required this.preferredGatewayUri,
    this.debugAndroidEmulatorGatewayUri,
    required this.credential,
    required this.certSha256,
    this.connectTimeout = defaultConnectTimeout,
    CodePetDiscovery? discovery,
    this.hostDirectory,
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
  final Uri? debugAndroidEmulatorGatewayUri;
  final String credential;
  final String certSha256;
  final Duration connectTimeout;
  final CodePetDiscovery discovery;
  final CodePetHostDirectory? hostDirectory;
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
  bool shouldPersistSelectedGatewayUri = false;

  @override
  Stream<JsonMap> get events => _events.stream;

  @override
  Future<void> connect() async {
    _throwIfClosed();
    final attempted = <Uri>{};
    Object? discoveryError;
    Future<bool> tryDiscoveredHost(DiscoveredCodePetHost? host) async {
      if (host == null ||
          !isTrustedDiscoveryCandidate(host, deviceId, certSha256)) {
        return false;
      }
      final candidate = preferredGatewayUri.replace(
        host: host.host,
        port: host.port,
      );
      if (!attempted.add(candidate)) return false;
      try {
        await _tryCandidate(candidate);
        return true;
      } catch (error) {
        discoveryError = error;
        return false;
      }
    }

    Object? debugAndroidEmulatorError;
    final debugAndroidEmulatorCandidate = debugAndroidEmulatorGatewayUri;
    if (debugAndroidEmulatorCandidate != null &&
        attempted.add(debugAndroidEmulatorCandidate)) {
      try {
        await _tryCandidate(
          debugAndroidEmulatorCandidate,
          persistAfterValidation: false,
        );
        return;
      } catch (error) {
        debugAndroidEmulatorError = error;
      }
    }
    _throwIfClosed();
    if (await tryDiscoveredHost(hostDirectory?.currentHost(deviceId))) {
      return;
    }
    _throwIfClosed();
    Object? preferredError;
    if (attempted.add(preferredGatewayUri)) {
      try {
        await _tryCandidate(preferredGatewayUri);
        return;
      } catch (error) {
        preferredError = error;
      }
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
    if (await tryDiscoveredHost(hostDirectory?.currentHost(deviceId))) {
      return;
    }
    _throwIfClosed();
    final directory = hostDirectory;
    if (directory != null) {
      try {
        await for (final host in directory
            .watchHost(deviceId)
            .timeout(connectTimeout)) {
          _throwIfClosed();
          if (await tryDiscoveredHost(host)) return;
        }
      } catch (error) {
        if (_closed) rethrow;
        discoveryError ??= error;
      }
    } else {
      try {
        await for (final host in discovery.discover()) {
          _throwIfClosed();
          if (await tryDiscoveredHost(host)) return;
        }
      } catch (error) {
        if (_closed) rethrow;
        discoveryError = error;
      }
    }
    final debugAndroidEmulatorSummary = debugAndroidEmulatorCandidate == null
        ? ''
        : 'Android emulator alias: $debugAndroidEmulatorError; ';
    throw GatewayConnectionException(
      '${debugAndroidEmulatorSummary}Preferred endpoint, stable port, and '
      'trusted mDNS candidates failed. '
      'Preferred: $preferredError; stable: $stableError; '
      'discovery: $discoveryError',
      retryable: [
        debugAndroidEmulatorError,
        preferredError,
        stableError,
        discoveryError,
      ]
          .whereType<Object>()
          .every(isRetryableGatewayFailure),
    );
  }

  Future<void> _tryCandidate(
    Uri gatewayUri, {
    bool persistAfterValidation = true,
  }) async {
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
      shouldPersistSelectedGatewayUri = persistAfterValidation;
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
  Future<Object?> request(Map<String, Object?> request) {
    final active = _active;
    if (active == null) {
      throw const GatewayConnectionException(
        'Gateway endpoint is not connected',
        retryable: true,
      );
    }
    return active.request(request);
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
  String trustedFingerprint,
) {
  const allowedKeys = {'id', 'name', 'fp', 'vmin', 'vmax', 'pair'};
  const requiredKeys = {'id', 'name', 'vmin', 'vmax', 'pair'};
  if (host.txt.keys.toSet().difference(allowedKeys).isNotEmpty ||
      !requiredKeys.every(host.txt.containsKey) ||
      host.txt['id'] != trustedDeviceId) {
    return false;
  }
  final minimum = int.tryParse(host.txt['vmin'] ?? '');
  final maximum = int.tryParse(host.txt['vmax'] ?? '');
  final fingerprint = host.txt['fp'];
  return fingerprint == trustedFingerprint &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint ?? '') &&
      minimum != null && maximum != null && minimum <= 1 && maximum >= 1;
}
