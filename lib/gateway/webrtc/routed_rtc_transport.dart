import 'dart:async';

import '../../core/domain/models.dart';
import '../../application/errors/application_failures.dart';
import '../../discovery/codepet_discovery.dart';
import '../../discovery/resolving_gateway_transport.dart';
import '../../diagnostics/app_log.dart';
import '../transport.dart';
import 'cloud_signaling.dart';
import 'signaling.dart';
import 'webrtc_gateway_transport.dart';

/// Selects a signaling route before the Gateway handshake. Never replays RPCs.
class RoutedRtcTransport
    implements
        GatewayTransport,
        EndpointAwareGatewayTransport,
        EndpointPersistenceAwareGatewayTransport {
  RoutedRtcTransport({
    required String deviceId,
    required Uri preferredGatewayUri,
    Uri? debugAndroidEmulatorGatewayUri,
    required String credential,
    required String certSha256,
    CodePetHostDirectory? hostDirectory,
  }) : pairing = CloudPairing(deviceId, credential, certSha256),
       local = ResolvingPinnedGatewayTransport(
         deviceId: deviceId,
         preferredGatewayUri: preferredGatewayUri,
         debugAndroidEmulatorGatewayUri: debugAndroidEmulatorGatewayUri,
         credential: credential,
         certSha256: certSha256,
         hostDirectory: hostDirectory,
         connectTimeout: const Duration(seconds: 25),
         transportFactory: (uri, credential, pin) => WebRtcGatewayTransport(
           signaling: PinnedLanRtcSignaling(
             gatewayUri: uri,
             credential: credential,
             certSha256: pin,
           ),
         ),
       );
  final CloudPairing pairing;
  final ResolvingPinnedGatewayTransport local;
  final _events = StreamController<JsonMap>.broadcast();
  GatewayTransport? _active;
  StreamSubscription<JsonMap>? _subscription;
  bool _closed = false;
  Timer? _leaseTimer;
  @override
  Stream<JsonMap> get events => _events.stream;
  @override
  Uri? get selectedGatewayUri =>
      identical(_active, local) ? local.selectedGatewayUri : null;
  @override
  bool get shouldPersistSelectedGatewayUri =>
      identical(_active, local) && local.shouldPersistSelectedGatewayUri;

  @override
  Future<void> connect() async {
    if (_closed) throw const GatewayConnectionException('RTC route closed');
    try {
      await local.connect().timeout(const Duration(seconds: 8));
      if (_closed) {
        await local.close();
        return;
      }
      _active = local;
      _subscription = local.events.listen(
        _events.add,
        onError: _events.addError,
      );
      try {
        await pairing.bootstrap(local.selectedGatewayUri!);
        AppLog.named('gateway.rtc').info('Cloud pairing upgrade completed');
      } catch (_) {
        AppLog.named('gateway.rtc')
            .info('Cloud pairing unavailable; LAN RTC remains active');
      }
      return;
    } catch (error) {
      await local.close();
      if (_closed || !isRetryableGatewayFailure(error)) rethrow;
    }
    final state = await pairing.load();
    if (state == null || state['token'] == null) {
      throw const GatewayConnectionException('请先在同一局域网连接新版 Host，完成公网通道授权。');
    }
    if (_closed) throw const GatewayConnectionException('RTC route closed');
    final signaling = CloudRtcSignaling(state);
    final transport = WebRtcGatewayTransport(
      signaling: signaling,
      connectTimeout: const Duration(seconds: 55),
    );
    _active = transport;
    _subscription = transport.events.listen(
      _events.add,
      onError: _events.addError,
    );
    try {
      await transport.connect();
    } catch (_) {
      await close();
      rethrow;
    }
    if (_closed) {
      await transport.close();
      return;
    }
    final path = await transport.selectedPathKind();
    AppLog.named('gateway.rtc')
        .info('Cloud signaling established RTC Gateway route; path=$path');
    // Reconnect before temporary TURN credentials expire; no request is replayed.
    final remaining =
        (signaling.iceExpires! * 1000) -
        DateTime.now().millisecondsSinceEpoch -
        300000;
    _leaseTimer = Timer(
      Duration(milliseconds: remaining.clamp(1000, 86400000)),
      () {
        _events.addError(
          const GatewayConnectionException(
            'RTC relay credential renewal',
            retryable: true,
            outcomeUnknown: true,
          ),
        );
        unawaited(close());
      },
    );
  }

  @override
  Future<Object?> request(Map<String, Object?> request) {
    if (_closed || _active == null) {
      throw const GatewayConnectionException('RTC route not connected');
    }
    return _active!.request(request);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _leaseTimer?.cancel();
    await _subscription?.cancel();
    await local.close();
    if (!identical(_active, local)) await _active?.close();
    await _events.close();
  }
}
