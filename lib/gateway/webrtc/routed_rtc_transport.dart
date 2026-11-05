import 'dart:async';

import '../../core/domain/models.dart';
import '../../application/errors/application_failures.dart';
import '../../discovery/codepet_discovery.dart';
import '../../discovery/resolving_gateway_transport.dart';
import '../../diagnostics/app_log.dart';
import '../transport.dart';
import 'cloud_signaling.dart';
import 'path_policy.dart';
import 'rtc_diagnostics.dart';
import 'webrtc_gateway_transport.dart';

/// A fresh transport for one independent, bounded connection attempt.
class RtcRouteAttempt {
  RtcRouteAttempt(
    this.name,
    this.transport, {
    this.timeout = const Duration(seconds: 55),
    this.relayExpires,
    this.connectionId,
  });
  final String name;
  final String? connectionId;
  final GatewayTransport transport;
  final Duration timeout;
  final int? Function()? relayExpires;
}

/// Races LAN/WSS, IPv6 direct, IPv4 direct and TURN before the Gateway handshake.
/// Only the winner carries business RPCs. Requests are never replayed on losers.
class RoutedRtcTransport
    implements
        GatewayTransport,
        EndpointAwareGatewayTransport,
        EndpointPersistenceAwareGatewayTransport {
  factory RoutedRtcTransport({
    required String deviceId,
    required Uri preferredGatewayUri,
    Uri? debugAndroidEmulatorGatewayUri,
    required String credential,
    required String certSha256,
    CodePetHostDirectory? hostDirectory,
  }) {
    final diagnostics = RtcDiagnostics();
    diagnostics.raceId = diagnostics.connectionId;
    diagnostics.emit("race.target", {"targetId": rtcOfferId(deviceId)});
    final pairing = CloudPairing(deviceId, credential, certSha256);
    final local = ResolvingPinnedGatewayTransport(
      deviceId: deviceId,
      preferredGatewayUri: preferredGatewayUri,
      debugAndroidEmulatorGatewayUri: debugAndroidEmulatorGatewayUri,
      credential: credential,
      certSha256: certSha256,
      hostDirectory: hostDirectory,
    );
    return RoutedRtcTransport.withRoutes(
      local: local,
      diagnostics: diagnostics,
      bootstrap: pairing.bootstrap,
      cloudRoutes: () async {
        final state = await pairing.load();
        if (state == null || state['token'] == null) {
          throw const GatewayConnectionException('尚无公网通道授权，请扫描新版 Host 的配对二维码。');
        }
        return [
          for (final policy in [
            RtcPathPolicy.ipv6Direct,
            RtcPathPolicy.ipv4Direct,
            RtcPathPolicy.relay,
          ])
            _cloudAttempt(state, policy, diagnostics.connectionId),
        ];
      },
    );
  }

  /// Injection boundary for deterministic race/cancellation tests, without native ICE.
  RoutedRtcTransport.withRoutes({
    required this.local,
    required Future<List<RtcRouteAttempt>> Function() cloudRoutes,
    Future<void> Function(Uri)? bootstrap,
    this.lanTimeout = const Duration(seconds: 8),
    RtcDiagnostics? diagnostics,
    // Keep the public injection names independent of private storage.
    // ignore: prefer_initializing_formals
  }) : _cloudRoutes = cloudRoutes,
       // ignore: prefer_initializing_formals
       _bootstrap = bootstrap,
       _diagnostics = diagnostics ?? RtcDiagnostics() {
    _diagnostics.raceId ??= _diagnostics.connectionId;
  }

  static RtcRouteAttempt _cloudAttempt(
    Map<String, dynamic> state,
    RtcPathPolicy policy,
    String raceId,
  ) {
    final diagnostics = RtcDiagnostics(
      raceId: raceId,
      pathPolicy: policy.wireName,
    );
    final signaling = CloudRtcSignaling(
      state,
      pathPolicy: policy,
      diagnostics: diagnostics,
    );
    return RtcRouteAttempt(
      policy.wireName,
      WebRtcGatewayTransport(
        signaling: signaling,
        diagnostics: diagnostics,
        pathPolicy: policy,
        connectTimeout: const Duration(seconds: 55),
      ),
      connectionId: diagnostics.connectionId,
      relayExpires: policy == RtcPathPolicy.relay
          ? () => signaling.iceExpires
          : null,
    );
  }

  final RtcDiagnostics _diagnostics;
  final _pathResults = <String, String>{};
  final GatewayTransport local;
  final Duration lanTimeout;
  final Future<List<RtcRouteAttempt>> Function() _cloudRoutes;
  final Future<void> Function(Uri)? _bootstrap;
  final _events = StreamController<JsonMap>.broadcast();
  final _attempts = <GatewayTransport>{};
  final _subscriptions = <GatewayTransport, StreamSubscription<JsonMap>>{};
  final _attemptEnds = <GatewayTransport, Completer<void>>{};
  final _failures = <Object>[];
  final _result = Completer<void>();
  GatewayTransport? _active;
  Future<void>? _connecting;
  Future<void>? _closing;
  bool _closed = false;
  int _pending = 0;
  Timer? _leaseTimer;
  String? selectedRoute;

  @override
  Stream<JsonMap> get events => _events.stream;
  @override
  Uri? get selectedGatewayUri =>
      identical(_active, local) && local is EndpointAwareGatewayTransport
      ? (local as EndpointAwareGatewayTransport).selectedGatewayUri
      : null;
  @override
  bool get shouldPersistSelectedGatewayUri =>
      identical(_active, local) &&
      local is EndpointPersistenceAwareGatewayTransport &&
      (local as EndpointPersistenceAwareGatewayTransport)
          .shouldPersistSelectedGatewayUri;

  @override
  Future<void> connect() => _connecting ??= _connect();

  Future<void> _connect() async {
    if (_closed) throw const GatewayConnectionException('RTC route closed');
    // Count discovery before starting LAN: even an immediate LAN failure must
    // wait for the cloud candidates, rather than completing the race early.
    _diagnostics.emit("race.start", {
      "paths": ["lan", "ipv6-direct", "ipv4-direct", "relay"],
    });
    _pending = 1;
    _start(RtcRouteAttempt('lan', local, timeout: lanTimeout));
    unawaited(_startCloud());
    await _result.future;
  }

  Future<void> _startCloud() async {
    _diagnostics.emit("race.cloudLoad.start");
    var accepting = true;
    try {
      final routes = await _cloudRoutes()
          .then((routes) {
            // A late secure-storage result must not allocate abandoned transports
            // after this loader timed out, the race completed, or the user closed it.
            if (!accepting || _closed || _active != null) {
              for (final route in routes) {
                unawaited(_discard(route.transport));
              }
              return <RtcRouteAttempt>[];
            }
            return routes;
          })
          .timeout(const Duration(seconds: 10));
      _diagnostics.emit("race.cloudLoad.complete", {
        "routeCount": routes.length,
      });
      for (final route in routes) {
        if (_closed || _active != null) {
          unawaited(_discard(route.transport));
        } else {
          _start(route);
        }
      }
    } catch (error) {
      _failures.add(error);
      _diagnostics.emit("race.cloudLoad.failed", rtcFailure(error));
    } finally {
      accepting = false;
      _pending--;
      _finishIfFailed();
    }
  }

  void _start(RtcRouteAttempt route) {
    _pending++;
    _attempts.add(route.transport);
    _pathResults[route.name] = "connecting";
    _diagnostics.emit("race.path.start", {
      "path": route.name,
      "rtcConnectionId": route.connectionId,
      "timeoutMs": route.timeout.inMilliseconds,
    });
    unawaited(_run(route));
  }

  Future<void> _run(RtcRouteAttempt route) async {
    final started = Stopwatch()..start();
    final transport = route.transport;
    final ended = Completer<void>();
    _attemptEnds[transport] = ended;
    // Listen immediately, but never publish a losing attempt's events/errors.
    _subscriptions[transport] = transport.events.listen(
      (event) {
        if (!_closed && identical(_active, transport)) _events.add(event);
      },
      onError: (Object error, StackTrace stack) {
        if (!_closed && identical(_active, transport)) {
          _diagnostics.emit("race.winner.error", {
            "path": route.name,
            ...rtcFailure(error),
          });
          _events.addError(error, stack);
        } else if (!ended.isCompleted) {
          ended.completeError(error, stack);
        }
      },
      onDone: () {
        if (!ended.isCompleted) {
          ended.completeError(
            const GatewayConnectionException('Route closed', retryable: true),
          );
        }
      },
    );
    try {
      await Future.any([Future<void>.sync(transport.connect), ended.future])
          .timeout(route.timeout);
      if (_closed || _active != null) return;
      _active = transport;
      selectedRoute = route.name;
      _pathResults[route.name] = "selected";
      _diagnostics.emit("race.selected", {
        "path": route.name,
        "durationMs": started.elapsedMilliseconds,
        "paths": Map.of(_pathResults),
      });
      _armRelayRenewal(route.relayExpires?.call());
      AppLog.named('gateway.rtc')
          .info('Gateway race selected path=${route.name}');
      _result.complete();
      // Do not wait for native cleanup or cloud bootstrap to return a usable LAN.
      for (final loser
          in _attempts.where((t) => !identical(t, transport)).toList()) {
        unawaited(_discard(loser));
      }
      final uri = selectedGatewayUri;
      if (uri != null && _bootstrap != null) unawaited(_upgradePairing(uri));
    } catch (error) {
      final cancelled =
          _closed || (_active != null && !identical(_active, transport));
      _pathResults[route.name] = cancelled ? "cancelled" : "failed";
      _diagnostics.emit("race.path.result", {
        "path": route.name,
        "outcome": _pathResults[route.name],
        "durationMs": started.elapsedMilliseconds,
        if (!cancelled) ...rtcFailure(error),
        if (cancelled)
          "reason": _closed ? "routeClosed" : "anotherPathSelected",
      });
      if (!cancelled) _failures.add(error);
      AppLog.named(
        'gateway.rtc',
      ).info('Gateway path=${route.name} unavailable (${error.runtimeType})');
    } finally {
      if (!identical(_active, transport)) await _discard(transport);
      _pending--;
      _finishIfFailed();
    }
  }

  Future<void> _upgradePairing(Uri uri) async {
    try {
      await _bootstrap!(uri);
    } catch (_) {
      AppLog.named('gateway.rtc')
          .info('Cloud pairing unavailable; LAN remains active');
    }
  }

  void _finishIfFailed() {
    if (_pending != 0 || _closed || _result.isCompleted) return;
    // Preserve authorization failures if no independently authenticated route won.
    final error =
        _failures.where((e) => !isRetryableGatewayFailure(e)).firstOrNull ??
        const GatewayConnectionException(
          '所有连接通道均不可用，请检查网络和 Host 状态。',
          retryable: true,
        );
    _diagnostics.emit("race.failed", {
      "paths": Map.of(_pathResults),
      ...rtcFailure(error),
    });
    _result.completeError(error);
    unawaited(close());
  }

  void _armRelayRenewal(int? expires) {
    if (expires == null) return;
    final remaining =
        expires * 1000 - DateTime.now().millisecondsSinceEpoch - 300000;
    _leaseTimer = Timer(
      Duration(milliseconds: remaining.clamp(1000, 86400000)),
      () {
        if (_closed) return;
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

  Future<void> _discard(GatewayTransport transport) async {
    final ended = _attemptEnds.remove(transport);
    if (ended != null && !ended.isCompleted) {
      // Settle the pending race immediately, including its timeout timer, even
      // if a platform connect future cannot itself be cancelled.
      ended.completeError(const GatewayConnectionException('Route cancelled'));
    }
    await _subscriptions.remove(transport)?.cancel();
    try {
      await transport.close();
    } catch (_) {}
  }

  @override
  Future<Object?> request(Map<String, Object?> request) {
    if (_closed || _active == null) {
      throw const GatewayConnectionException('RTC route not connected');
    }
    return _active!.request(request);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _diagnostics.emit("race.close", {
      "selectedPath": selectedRoute,
      "paths": Map.of(_pathResults),
    });
    _leaseTimer?.cancel();
    if (_connecting != null && !_result.isCompleted) {
      _result.completeError(
        const GatewayConnectionException('RTC route closed'),
      );
    }
    await Future.wait({..._attempts, local}.map(_discard));
    await _events.close();
  }
}
