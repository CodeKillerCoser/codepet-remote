import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:codepet_connection_engine/codepet_connection_engine.dart' as ce;
import 'package:codepet_channel_control_sdk/codepet_channel_control_sdk.dart'
    as control;
import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../../application/errors/application_failures.dart';
import '../../core/domain/connection_traffic.dart';
import '../../core/domain/models.dart';
import '../../diagnostics/app_log.dart';
import '../transport.dart';

/// Gateway session bridge. Business knowledge stays here, outside the engine.
/// Prepared candidates validate the handshake but never subscribe or send writes.
final class EngineGatewayTransport
    implements
        GatewayTransport,
        MetricsGatewayTransport,
        EndpointAwareGatewayTransport,
        EndpointPersistenceAwareGatewayTransport,
        ManagedGatewayTransport,
        ce.ConnectionHandover {
  EngineGatewayTransport({
    required this.targetId,
    required this.openTransport,
    required this.kinds,
    ce.CandidateBudget? budget,
    this.onPreparedEndpoint,
    ce.ConnectionPolicy policy = const ce.ConnectionPolicy(),
  }) {
    _engine = ce.ConnectionEngine(
      handover: this,
      budget: budget,
      policy: policy,
      onDiagnostic: (event, fields) => _log.info(
        'Connection engine $event ${fields.entries.map((e) => '${e.key}=${e.value}').join(' ')}',
      ),
    );
    _states = _engine.changes.listen(_stateChanged);
  }
  final Future<void> Function(Uri)? onPreparedEndpoint;
  final String targetId;
  final List<ce.ChannelKind> kinds;
  final Future<GatewayTransport> Function(ce.ChannelKind, ce.Cancellation)
  openTransport;
  final _log = AppLog.named('connection.engine');
  final String _sessionId =
      '${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 32)}';
  late final ce.ConnectionEngine _engine;
  late final StreamSubscription<ce.ConnectionSnapshot> _states;
  final _events = StreamController<JsonMap>.broadcast();
  final _availability = StreamController<bool>.broadcast();
  final _initial = Completer<_PreparedGateway>();
  Map<String, Object?>? _handshake;
  _PreparedGateway? _active;
  String? _cursor;
  int _environment = 0, _serial = 0, _inflight = 0, _waiting = 0;
  bool _optimize = true;
  bool _closed = false, _subscribed = false, _online = false;
  Completer<void>? _barrier, _drained;
  Future<void>? _closing;
  @override
  Stream<JsonMap> get events => _events.stream;
  @override
  Stream<bool> get availability => _availability.stream;
  @override
  ConnectionTraffic? get connectionTraffic => _online ? _active?.metrics : null;
  @override
  Uri? get selectedGatewayUri {
    final source = _active?.transport;
    return source is EndpointAwareGatewayTransport
        ? (source as EndpointAwareGatewayTransport).selectedGatewayUri
        : null;
  }

  @override
  bool get shouldPersistSelectedGatewayUri {
    final source = _active?.transport;
    return source is EndpointPersistenceAwareGatewayTransport &&
        (source as EndpointPersistenceAwareGatewayTransport)
            .shouldPersistSelectedGatewayUri;
  }

  @override
  Future<void> connect() async {
    if (_closed) {
      throw const GatewayConnectionException('Connection engine closed');
    }
    // Candidate preparation needs the application's generated handshake envelope.
  }

  void _stateChanged(ce.ConnectionSnapshot state) {
    if (_closed) return;
    final available = state.phase == ce.ConnectionPhase.online;
    if (!available) _active = null;
    if (_online != available) {
      _online = available;
      _availability.add(available);
    }
    if (available && !_initial.isCompleted) _initial.complete(_active!);
    if (state.phase == ce.ConnectionPhase.blocked) {
      final error = GatewayConnectionException(
        'Connection blocked: ${state.errorCode}',
      );
      if (!_initial.isCompleted) {
        _initial.completeError(error);
      } else {
        _events.addError(error);
      }
    }
  }

  @override
  void reconcile({bool? optimize}) {
    if (optimize != null) _optimize = optimize;
    if (_closed || _handshake == null) return;
    _active?.forceProbe = true;
    _environment++;
    _reconcile();
  }

  void _reconcile() {
    _engine.reconcile(
      ce.ConnectionTarget(
        id: targetId,
        authorizationRevision: 0,
        environmentRevision: _environment,
        optimize: _optimize,
        routes: [
          for (final kind in kinds)
            ce.CandidateRoute(
              kind: kind,
              timeout: kind == ce.ChannelKind.lan
                  ? const Duration(seconds: 12)
                  : const Duration(seconds: 60),
              open: (cancel) => _prepare(kind, cancel),
            ),
        ],
      ),
    );
  }

  @override
  void reportUnhealthy() => _active?.unusable();

  Future<ce.PreparedConnection> _prepare(
    ce.ChannelKind kind,
    ce.Cancellation cancel,
  ) async {
    final transport = await openTransport(kind, cancel);
    final candidate = _PreparedGateway(
      this,
      transport,
      kind,
      '$_sessionId-${++_serial}',
    );
    unawaited(
      cancel.whenCancelled.then((_) => candidate.close()).catchError((
        Object error,
      ) {
        _log.warning(
          'Cancelled transport cleanup failed type=${error.runtimeType}',
        );
      }),
    );
    try {
      cancel.check();
      await transport.connect();
      cancel.check();
      if (candidate.supportsControl) {
        final prepared = await candidate.controlCall(
          'prepare',
          control.ControlPrepare(sessionId: _sessionId).toJson(),
        );
        candidate.controlId = prepared.connectionId;
      }
      final response = await transport.request({
        ..._handshake!,
        'id': candidate.nextId(),
      });
      final envelope = sdk.ProtocolResponseEnvelope.fromJson(
        response,
        method: sdk.ProtocolMethod.protocolHandshake,
      );
      if (envelope.response case sdk.ProtocolFailure(:final error)) {
        final failure = error;
        throw ce.ConnectionFailure(
          'handshake_${failure.code}',
          permanent: failure.data?['retryable'] != true,
        );
      }
      final handshake =
          (envelope.response as sdk.ProtocolSuccess).result
              as sdk.HandshakeResponse;
      if (handshake.protocol.version != sdk.protocolVersion) {
        throw const ce.ConnectionFailure(
          'protocol_version_mismatch',
          permanent: true,
        );
      }
      candidate.handshake = handshake.toJson();
      candidate.handshakeCursor = handshake.eventCursor;
      if (kind == ce.ChannelKind.lan &&
          transport is EndpointAwareGatewayTransport) {
        final endpoint =
            (transport as EndpointAwareGatewayTransport).selectedGatewayUri;
        if (endpoint != null && onPreparedEndpoint != null) {
          unawaited(
            onPreparedEndpoint!(endpoint).catchError((Object error) {
              _log.warning(
                'Cloud bootstrap unavailable type=${error.runtimeType}',
              );
            }),
          );
        }
      }
      cancel.check();
      return candidate;
    } catch (error) {
      try {
        await candidate.close();
      } catch (_) {
        throw const ce.ConnectionFailure(
          'candidate_cleanup_failed',
          unreleasedResources: true,
        );
      }
      if (error is ce.ConnectionFailure) rethrow;
      if (error is FormatException || error is sdk.ProtocolCodecException) {
        throw const ce.ConnectionFailure(
          'invalid_peer_protocol',
          permanent: true,
        );
      }
      if (error is GatewayConnectionException && !error.retryable) {
        throw const ce.ConnectionFailure('peer_rejected', permanent: true);
      }
      rethrow;
    }
  }

  @override
  Future<bool> activate(
    ce.PreparedConnection? previous,
    ce.PreparedConnection next,
    ce.Cancellation cancellation,
  ) async {
    final old = previous as _PreparedGateway?;
    final candidate = next as _PreparedGateway;
    // Old peers cannot safely fence a healthy connection: recover only.
    if (old != null && (!old.supportsControl || !candidate.supportsControl)) {
      return false;
    }
    final barrier = _barrier = Completer<void>();
    var ownershipCommitted = false;
    try {
      if (old != null && _inflight != 0) {
        _drained ??= Completer<void>();
        try {
          await _drained!.future.timeout(const Duration(seconds: 1));
        } on TimeoutException {
          return false;
        }
      }
      cancellation.check();
      if (candidate.supportsControl) {
        final status = await candidate.controlCall('status', const {});
        final switchId = candidate.nextId();
        try {
          final committed = await candidate.controlCall(
            'activate',
            control.ControlActivate(
              expectedActive: status.activeConnectionId,
              switchId: switchId,
            ).toJson(),
          );
          if (committed.activeConnectionId != candidate.controlId) {
            throw const ce.ConnectionFailure(
              'ownership_mismatch',
              permanent: true,
            );
          }
        } catch (_) {
          // Never guess after an ambiguous commit. Query the same host scope.
          try {
            final resolved = await candidate.controlCall('status', const {});
            if (resolved.activeConnectionId != candidate.controlId) {
              if (old != null && resolved.activeConnectionId == old.controlId) {
                return false;
              }
              throw const ce.ConnectionFailure(
                'ownership_unknown',
                permanent: true,
              );
            }
          } catch (_) {
            throw const ce.ConnectionFailure(
              'activation_outcome_unknown',
              permanent: true,
            );
          }
        }
      }
      ownershipCommitted = true;
      cancellation.check();
      candidate.buffering = true;
      if (_subscribed) {
        final response = await candidate.transport.request({
          'jsonrpc': '2.0',
          'id': candidate.nextId(),
          'method': 'event.subscribe',
          'params': {'afterCursor': _cursor ?? candidate.handshakeCursor},
        });
        final envelope = sdk.ProtocolResponseEnvelope.fromJson(
          response,
          method: sdk.ProtocolMethod.eventSubscribe,
        );
        if (envelope.response is sdk.ProtocolFailure) {
          // A replay gap needs business snapshot rebuilding; do not silently skip.
          _events.addError(
            const GatewayConnectionException(
              'Event replay requires a fresh snapshot',
              retryable: true,
            ),
          );
          throw const ce.ConnectionFailure(
            'event_recovery_failed',
            permanent: true,
          );
        }
      }
      cancellation.check();
      _active = candidate;
      candidate.buffering = false;
      for (final event in candidate.buffered) {
        _forward(candidate, event);
      }
      candidate.buffered.clear();
      return true;
    } catch (error) {
      if (ownershipCommitted && !cancellation.isCancelled) {
        throw const ce.ConnectionFailure(
          'committed_channel_recovery_failed',
          permanent: true,
        );
      }
      rethrow;
    } finally {
      if (identical(_barrier, barrier)) _barrier = null;
      barrier.complete();
    }
  }

  void _forward(_PreparedGateway candidate, JsonMap event) {
    if (_closed || !identical(candidate, _active)) return;
    final cursor = (event['params'] as Map?)?['eventCursor'];
    if (cursor is String) _cursor = cursor;
    _events.add(event);
  }

  @override
  Future<Object?> request(Map<String, Object?> request) async {
    if (_closed) throw const GatewayConnectionException('Connection closed');
    if (request['method'] == 'protocol.handshake') {
      if (_handshake != null) {
        throw const GatewayConnectionException('Handshake already completed');
      }
      _handshake = Map.of(request);
      _reconcile();
      final ready = await _initial.future;
      return {'jsonrpc': '2.0', 'id': request['id'], 'result': ready.handshake};
    }
    final barrier = _barrier;
    if (barrier != null) {
      if (_waiting >= 64) {
        throw const GatewayConnectionException(
          'Connection handover queue is full',
          retryable: true,
        );
      }
      _waiting++;
      try {
        await barrier.future.timeout(const Duration(seconds: 10));
      } finally {
        _waiting--;
      }
    }
    final connection = _active;
    if (connection == null || connection.closed) {
      throw const GatewayConnectionException(
        'Connection is recovering',
        retryable: true,
      );
    }
    _inflight++;
    try {
      if (request['method'] == 'protocol.ping') {
        final pong = await connection.ping();
        return {
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {
            ...pong,
            'sequence': (request['params'] as Map)['sequence'],
          },
        };
      }
      final response = await connection.transport.request(request);
      if (!identical(connection, _active)) {
        throw const GatewayConnectionException(
          'Response belongs to a replaced channel',
          retryable: true,
          outcomeUnknown: true,
        );
      }
      if (request['method'] == 'event.subscribe' &&
          (response as Map)['error'] == null) {
        _subscribed = true;
        _cursor ??= (request['params'] as Map)['afterCursor'] as String;
      }
      return response;
    } finally {
      if (--_inflight == 0) {
        _drained?.complete();
        _drained = null;
      }
    }
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    if (!_initial.isCompleted && _handshake != null) {
      _initial.completeError(
        const GatewayConnectionException('Connection closed'),
      );
    }
    await _engine.dispose();
    await _states.cancel();
    await _availability.close();
    await _events.close();
  }
}

final class _PreparedGateway implements ce.PreparedConnection {
  _PreparedGateway(this.owner, this.transport, this.channel, this._localId) {
    _subscription = transport.events.listen(
      (event) {
        if (buffering) {
          _bufferBytes += utf8.encode(jsonEncode(event)).length;
          if (buffered.length >= 64 || _bufferBytes > 1024 * 1024) {
            _health.addError(
              const ce.ConnectionFailure(
                'handover_event_overflow',
                permanent: true,
              ),
            );
            return;
          }
          buffered.add(event);
        } else {
          owner._forward(this, event);
        }
      },
      onError: (Object error) {
        if (!closed) {
          _health.addError(
            error is GatewayConnectionException && !error.retryable
                ? const ce.ConnectionFailure(
                    'credential_rejected',
                    permanent: true,
                  )
                : error,
          );
        }
      },
      onDone: unusable,
    );
  }
  final EngineGatewayTransport owner;
  final GatewayTransport transport;
  @override
  final ce.ChannelKind channel;
  final String _localId;
  // Stable once preparation returns, shared with Host logs and ownership.
  @override
  String get id => controlId ?? _localId;
  String? controlId;
  late Map<String, Object?> handshake;
  late String handshakeCursor;
  final _health = StreamController<ce.ConnectionHealth>.broadcast();
  late final StreamSubscription<JsonMap> _subscription;
  final buffered = <JsonMap>[];
  bool closed = false, buffering = false, forceProbe = false;
  int _ids = 0, _sequence = 0, _bufferBytes = 0;
  Future<void>? _closing;
  Future<Map<String, Object?>>? _ping;
  Map<String, Object?>? _pong;
  final _sincePong = Stopwatch();
  String nextId() => 'channel-$id-${++_ids}';
  bool get supportsControl =>
      transport is ChannelControlGatewayTransport &&
      (transport as ChannelControlGatewayTransport).supportsChannelControl;
  ConnectionTraffic? get metrics => transport is MetricsGatewayTransport
      ? (transport as MetricsGatewayTransport).connectionTraffic
      : null;
  @override
  ce.TrafficSnapshot get traffic {
    final m = metrics;
    return ce.TrafficSnapshot(
      sentBytes: m?.sentBytes ?? 0,
      receivedBytes: m?.receivedBytes ?? 0,
      sentBytesPerSecond: m?.sentBytesPerSecond ?? 0,
      receivedBytesPerSecond: m?.receivedBytesPerSecond ?? 0,
    );
  }

  @override
  Stream<ce.ConnectionHealth> get healthChanges => _health.stream;
  void unusable() {
    if (!closed) _health.add(ce.ConnectionHealth.unusable);
  }

  @override
  Future<bool> probe(ce.Cancellation cancel) async {
    cancel.check();
    final before = metrics?.totalBytes ?? 0;
    try {
      await ping(force: forceProbe).timeout(const Duration(seconds: 4));
    } on TimeoutException {
      // A large ordered response can delay the pong. RTC exposes fragment
      // progress; Dart WSS exposes only complete messages, so keep its existing
      // 60 second application-heartbeat grace. Never extend grace indefinitely.
      final progress = (metrics?.totalBytes ?? 0) > before;
      final active = identical(owner._active, this);
      if (!active ||
          _pong == null ||
          _sincePong.elapsed >= const Duration(seconds: 60) ||
          !(progress || channel == ce.ChannelKind.lan || owner._inflight > 0)) {
        rethrow;
      }
    }
    forceProbe = false;
    return !closed && !cancel.isCancelled;
  }

  Future<Map<String, Object?>> ping({bool force = false}) async {
    if (!force &&
        _pong != null &&
        _sincePong.elapsed < const Duration(seconds: 10)) {
      return _pong!;
    }
    if (_ping != null) return _ping!;
    return _ping = () async {
      try {
        final sequence = ++_sequence;
        final response = await transport.request({
          'jsonrpc': '2.0',
          'id': nextId(),
          'method': 'protocol.ping',
          'params': {'sequence': sequence},
        });
        final envelope = sdk.ProtocolResponseEnvelope.fromJson(
          response,
          method: sdk.ProtocolMethod.protocolPing,
        );
        if (envelope.response is sdk.ProtocolFailure) {
          throw const ce.ConnectionFailure('heartbeat_rejected');
        }
        final pong =
            (envelope.response as sdk.ProtocolSuccess).result
                as sdk.PingResponse;
        if (pong.sequence != sequence) {
          throw const ce.ConnectionFailure(
            'heartbeat_sequence',
            permanent: true,
          );
        }
        _sincePong
          ..reset()
          ..start();
        return _pong = pong.toJson();
      } finally {
        _ping = null;
      }
    }();
  }

  Future<control.ControlStatus> controlCall(
    String operation,
    Map<String, Object?> params,
  ) async {
    final response = await transport
        .request({
          'channelControl': 1,
          'jsonrpc': '2.0',
          'id': nextId(),
          'operation': operation,
          'params': params,
        })
        .timeout(const Duration(seconds: 3));
    if (response is! Map ||
        response['channelControl'] != 1 ||
        response['error'] != null) {
      throw const ce.ConnectionFailure('channel_control_rejected');
    }
    return control.ControlStatus.fromJson(response['result']);
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    closed = true;
    try {
      await _subscription.cancel();
    } catch (error) {
      owner._log.warning(
        'Transport observer cleanup failed type=${error.runtimeType}',
      );
    }
    await transport.close();
    await _health.close();
  }
}
