import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../application/errors/application_failures.dart';
import '../../core/domain/connection_traffic.dart';
import '../connection_traffic_meter.dart';
import '../../core/domain/models.dart';
import '../transport.dart';
import 'framing.dart';
import 'rtc_diagnostics.dart';
import 'signaling.dart';
import 'path_policy.dart';

typedef RtcPeerFactory = Future<RTCPeerConnection> Function();

/// Native resource release was not confirmed. The connection engine must retain
/// its resource permit instead of starting unlimited replacement peers.
final class RtcCleanupException implements Exception {
  RtcCleanupException(this.steps);
  final List<String> steps;
  @override
  String toString() => 'RTC cleanup unconfirmed: ${steps.join(', ')}';
}

/// Carries unchanged Gateway JSON-RPC over a reliable, ordered DataChannel.
final class WebRtcGatewayTransport
    implements
        GatewayTransport,
        MetricsGatewayTransport,
        ChannelControlGatewayTransport {
  final _traffic = ConnectionTrafficMeter(channel: 'unknown');
  @override
  ConnectionTraffic get connectionTraffic => _traffic.snapshot;
  // Public peerFactory name is retained for existing callers.
  WebRtcGatewayTransport({
    required this.signaling,
    RtcPeerFactory? peerFactory,
    this.connectTimeout = const Duration(seconds: 25),
    this.requestTimeout = const Duration(seconds: 30),
    this.cleanupTimeout = const Duration(seconds: 2),
    this.enableChannelControl = false,
    this.pathPolicy = RtcPathPolicy.auto,
    RtcDiagnostics? diagnostics,
    // ignore: prefer_initializing_formals
  }) : _peerFactory = peerFactory,
       _diagnostics =
           diagnostics ?? RtcDiagnostics(pathPolicy: pathPolicy.wireName);

  final bool enableChannelControl;
  @override
  bool supportsChannelControl = false;
  final RtcSignaling signaling;
  final RtcPeerFactory? _peerFactory;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final Duration cleanupTimeout;
  final RtcPathPolicy pathPolicy;
  final _events = StreamController<JsonMap>.broadcast();
  final _pending = <String, Completer<Object?>>{};
  final _decoder = RtcDecoder();
  final RtcDiagnostics _diagnostics;
  String _stage = "created";
  int _stageStartedMs = 0;
  void _enter(String stage) {
    _diagnostics.emit("connect.stage", {
      "stage": stage,
      "previousStage": _stage,
      "previousStageMs":
          _diagnostics.clock.elapsedMilliseconds - _stageStartedMs,
    });
    _stage = stage;
    _stageStartedMs = _diagnostics.clock.elapsedMilliseconds;
  }

  Timer? _statsTimer;
  bool _sampling = false;
  final _statsLog = RtcStatsLogPolicy();
  int _receivedFrames = 0;
  int _messageFrames = 0;
  int? _messageStartedMs;
  int? _lastFragmentMs;
  int _lastProgressMs = 0;

  Future<void> _sampleStats(String reason) async {
    final peer = _peer;
    if (peer == null || _sampling) return;
    _sampling = true;
    try {
      final reports = await peer.getStats().timeout(const Duration(seconds: 1));
      final relevant = reports
          .where(
            (r) => const {
              'candidate-pair',
              'local-candidate',
              'remote-candidate',
              'transport',
              'data-channel',
            }.contains(r.type),
          )
          .toList();
      _traffic.channel = _selectedPathKind(reports);
      final sanitized = relevant
          .take(128)
          .map(
            (r) =>
                rtcStat(r, _diagnostics.offerId ?? _diagnostics.connectionId),
          )
          .toList();
      if (!_statsLog.shouldEmit(
        sanitized,
        _diagnostics.clock.elapsedMilliseconds,
        force: reason != 'periodic',
      )) {
        return;
      }
      _diagnostics.emit('ice.stats', {
        'reason': reason,
        'count': relevant.length,
        'truncated': relevant.length > 128,
        'reports': sanitized,
      });
    } catch (error) {
      _diagnostics.emit('ice.statsUnavailable', {
        'reason': reason,
        'errorType': error.runtimeType.toString(),
      });
    } finally {
      _sampling = false;
    }
  }

  RTCPeerConnection? _peer;
  RTCDataChannel? _channel;
  Future<void>? _connecting;
  Future<void>? _closing;
  Future<Object>? _creating;
  Future<void> _sendTail = Future<void>.value();
  Completer<void>? _gathered;
  bool _closed = false;
  bool _aborted = false;
  bool _connected = false;
  bool _compression = false;
  int _queuedBytes = 0;

  @override
  Stream<JsonMap> get events => _events.stream;

  /// Report only the selected ICE route; configured TURN servers are not proof.
  Future<String> selectedPathKind() async {
    final reports =
        await _peer?.getStats().timeout(const Duration(seconds: 1)) ?? [];
    return _traffic.channel = _selectedPathKind(reports);
  }

  String _selectedPathKind(List<StatsReport> reports) {
    final byId = {for (final report in reports) report.id: report};
    for (final report in reports) {
      if (report.type != 'transport') continue;
      final pair = byId[report.values['selectedCandidatePairId']];
      if (pair == null) continue;
      final local = byId[pair.values['localCandidateId']];
      final remote = byId[pair.values['remoteCandidateId']];
      if (local?.values['candidateType'] == 'relay' ||
          remote?.values['candidateType'] == 'relay') {
        return 'relay';
      }
      if (local != null && remote != null) {
        InternetAddress? address(StatsReport candidate) {
          final value = candidate.values['address'] ?? candidate.values['ip'];
          return value is String ? InternetAddress.tryParse(value) : null;
        }

        final localIp = address(local), remoteIp = address(remote);
        if (localIp == null ||
            remoteIp == null ||
            localIp.type != remoteIp.type) {
          return 'direct';
        }
        return localIp.type == InternetAddressType.IPv6
            ? 'ipv6-direct'
            : 'ipv4-direct';
      }
    }
    return 'unknown';
  }

  @override
  Future<void> connect() => _connecting ??= _connect();

  Future<void> _connect() async {
    try {
      await _open().timeout(connectTimeout);
    } catch (error) {
      final cancelled = _closed && !_aborted;
      if (!cancelled) unawaited(_diagnostics.networkSnapshot('connectFailed'));
      _diagnostics.emit(cancelled ? 'connect.cancelled' : 'connect.failed', {
        if (cancelled) 'reason': 'closed' else ...rtcFailure(error),
        'stage': _stage,
        'stageMs': _diagnostics.clock.elapsedMilliseconds - _stageStartedMs,
      });
      await close();
      throw _failure(error, unknown: false);
    }
  }

  Future<void> _open() async {
    _diagnostics.emit('connect.start');
    _checkNotClosed();
    _enter("iceConfiguration");
    final config = signaling is RtcIceSignaling
        ? await (signaling as RtcIceSignaling).configuration()
        : <String, dynamic>{'iceServers': <Object>[]};
    _checkNotClosed();
    _enter("peerCreation");
    final trickle =
        signaling is RtcTrickleSignaling &&
            (signaling as RtcTrickleSignaling).trickleEnabled
        ? signaling as RtcTrickleSignaling
        : null;
    final peerCreation = _createOwned(
      () => _peerFactory?.call() ?? createPeerConnection(config),
      (peer) => _peer = peer,
      (peer) => _releaseNative(peer: peer),
    );
    _creating = peerCreation;
    final peer = await peerCreation;
    _checkNotClosed();
    _diagnostics.emit('ice.configuration', {
      'policy': config['iceTransportPolicy'] ?? 'all',
      'serverCount': (config['iceServers'] as List?)?.length ?? 0,
      'candidateErrorCallback': 'notExposedByFlutterWebrtc',
      'trickleIce': trickle != null,
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_sampleStats('periodic'));
    });
    peer.onIceConnectionState = (state) {
      _diagnostics.emit('ice.state', {'state': state.name});
      unawaited(_sampleStats('iceState'));
    };
    peer.onSignalingState = (state) =>
        _diagnostics.emit('signaling.state', {'state': state.name});
    peer.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      if (line == null || line.isEmpty) return;
      _diagnostics.emit(
        'ice.localCandidate',
        _diagnostics.candidateDecision(line, pathPolicy),
      );
      if (pathPolicy.rejectionReason(line) == null) {
        trickle?.localCandidate({
          'candidate': line,
          'sdpMid': candidate.sdpMid,
          'sdpMLineIndex': candidate.sdpMLineIndex,
        });
      }
    };
    peer.onConnectionState = (state) {
      _diagnostics.emit('peer.state', {'state': state.name});
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        _abort(
          const GatewayConnectionException(
            'RTC peer closed',
            retryable: true,
            outcomeUnknown: true,
          ),
        );
      }
    };
    final gathered = _gathered = Completer<void>();
    peer.onIceGatheringState = (state) {
      _diagnostics.emit('ice.gathering', {'state': state.name});
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !gathered.isCompleted) {
        trickle?.localCandidate(null);
        gathered.complete();
      }
    };
    final channelCreation = _createOwned(
      () => peer.createDataChannel(
        'codepet.gateway.v1',
        RTCDataChannelInit()
          ..ordered = true
          ..negotiated = true
          ..id = 0
          ..protocol = 'codepet.gateway.cpg1',
      ),
      (channel) => _channel = channel,
      (channel) => _releaseNative(channel: channel),
    );
    _creating = channelCreation;
    final channel = await channelCreation;
    _checkNotClosed();
    channel.onMessage = _onMessage;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _abort(
          const GatewayConnectionException(
            'RTC channel closed',
            retryable: true,
            outcomeUnknown: true,
          ),
        );
      }
    };
    // flutter_webrtc otherwise defaults both receive-media constraints to true.
    _enter("candidateGathering");
    final offer = await peer.createOffer({
      'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
      'optional': <Object>[],
    });
    _checkNotClosed();
    await peer.setLocalDescription(offer);
    _checkNotClosed();
    if (await peer.getIceGatheringState() ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      trickle?.localCandidate(null);
    } else if (trickle == null) {
      await gathered.future;
    }
    _gathered = null;
    _checkNotClosed();
    final description = await peer.getLocalDescription();
    if (description?.sdp == null) {
      throw const FormatException('Missing RTC offer');
    }
    _diagnostics.filteredCandidates(
      'localOffer',
      description!.sdp!,
      pathPolicy,
    );
    final offerSdp =
        '${pathPolicy.filterSdp(description.sdp!, allowEmpty: trickle != null).trimRight()}\r\n$rtcCompressionSdp\r\n${enableChannelControl ? 'a=x-codepet-channel-control:1\r\n' : ''}';
    _diagnostics.offerId = rtcOfferId(offerSdp);
    _diagnostics.description('localOffer', offerSdp);
    _enter('signaling');
    _diagnostics.emit('signaling.offer.start');
    final answer = await signaling.answer({'type': 'offer', 'sdp': offerSdp});
    _checkNotClosed();
    if (answer['type'] != 'answer' || answer['sdp'] is! String) {
      throw const FormatException('Invalid RTC answer');
    }
    _diagnostics.emit('signaling.answer.received');
    _diagnostics.description('remoteAnswer', answer['sdp'] as String);
    _diagnostics.filteredCandidates(
      'remoteAnswer',
      answer['sdp'] as String,
      pathPolicy,
    );
    supportsChannelControl =
        enableChannelControl &&
        (answer['sdp'] as String)
            .split(RegExp(r'\r?\n'))
            .contains('a=x-codepet-channel-control:1');
    _enter("remoteDescription");
    _decoder.allowCompression = _compression = rtcSupportsCompression(
      answer['sdp'] as String,
    );
    _diagnostics.emit('channel.encoding', {
      'compression': _compression ? 'gzip' : 'none',
    });
    await peer.setRemoteDescription(
      RTCSessionDescription(
        pathPolicy.filterSdp(answer['sdp'] as String),
        'answer',
      ),
    );
    _enter("channelOpen");
    while (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      _checkNotClosed();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _enter("connected");
    _connected = true;
    trickle?.finishTrickle();
    _diagnostics.emit('channel.open');
    unawaited(_sampleStats('open'));
  }

  void _checkNotClosed() {
    if (signaling is RtcTrickleSignaling) {
      (signaling as RtcTrickleSignaling).checkTrickleFailure();
    }
    if (_closed) {
      throw const GatewayConnectionException(
        'RTC transport closed',
        retryable: true,
      );
    }
  }

  @override
  Future<Object?> request(Map<String, Object?> request) {
    if (!_connected || _closed) {
      return Future.error(
        const GatewayConnectionException(
          'RTC channel is not connected',
          retryable: true,
        ),
      );
    }
    final id = request['id'];
    if (id is! String ||
        id.isEmpty ||
        (request['method'] is! String &&
            !(supportsChannelControl &&
                request['channelControl'] == 1 &&
                request['operation'] is String)) ||
        _pending.containsKey(id)) {
      return Future.error(
        const FormatException('Invalid or duplicate Gateway request id'),
      );
    }
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(request)));
    if (bytes.length > rtcRequestBytes ||
        _pending.length >= 64 ||
        _queuedBytes + bytes.length > 2 * 1024 * 1024) {
      return Future.error(
        const GatewayConnectionException(
          'RTC request queue or message limit exceeded',
          retryable: true,
        ),
      );
    }
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _diagnostics.emit('rpc.queued', {
      'rpcId': rtcOfferId(id),
      'method': request['method'],
      'bytes': bytes.length,
      'pendingRequests': _pending.length,
    });
    _queuedBytes += bytes.length;
    final result = completer.future
        .timeout(
          requestTimeout,
          onTimeout: () {
            final error = GatewayConnectionException(
              '${request['method']} request timed out',
              retryable: true,
              outcomeUnknown: true,
            );
            _diagnostics.emit('rpc.timeout', {
              'rpcId': rtcOfferId(id),
              'method': request['method'],
            });
            throw error;
          },
        )
        .whenComplete(() {
          _pending.remove(id);
        });
    _sendTail = _sendTail.then((_) async {
      try {
        if (!_closed && _pending.containsKey(id)) {
          // Finish an in-flight message even after its caller times out: CPG1
          // cannot interleave messages. Heartbeat/transport closure ends stalls.
          await _send(bytes);
        }
      } catch (error) {
        _abort(_failure(error));
      } finally {
        _queuedBytes -= bytes.length;
      }
    });
    return result;
  }

  Future<void> _send(Uint8List bytes) async {
    final channel = _channel!;
    final started = Stopwatch()..start();
    final originalBytes = bytes.length;
    final encoded = rtcEncodeMessage(bytes, _compression);
    bytes = encoded.bytes;
    if (encoded.compressed) {
      _diagnostics.emit('message.compressed', {
        'originalBytes': originalBytes,
        'wireBytes': bytes.length,
      });
    }
    var waitMs = 0;
    if (bytes.length >= rtcFrameBytes) {
      _diagnostics.emit('message.send.start', {'bytes': bytes.length});
    }
    for (var offset = 0; offset < bytes.length;) {
      _checkNotClosed();
      if (await channel.getBufferedAmount() > 64 * 1024) {
        final waiting = Stopwatch()..start();
        _diagnostics.emit('send.backpressure.start', {
          'offset': offset,
          'total': bytes.length,
        });
        while (await channel.getBufferedAmount() > 16 * 1024) {
          _checkNotClosed();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        waitMs += waiting.elapsedMilliseconds;
        _diagnostics.emit('send.backpressure.end', {
          'waitMs': waiting.elapsedMilliseconds,
          'offset': offset,
        });
      }
      _checkNotClosed();
      final end = (offset + rtcFrameBytes - rtcHeaderBytes).clamp(
        0,
        bytes.length,
      );
      await channel.send(
        RTCDataChannelMessage.fromBinary(
          rtcFragment(
            bytes.length,
            offset,
            Uint8List.sublistView(bytes, offset, end),
            compressed: encoded.compressed,
          ),
        ),
      );
      _traffic.sent(end - offset);
      offset = end;
    }
    if (bytes.length >= rtcFrameBytes ||
        started.elapsedMilliseconds >= 1000 ||
        waitMs > 0) {
      _diagnostics.emit('message.send.complete', {
        'bytes': bytes.length,
        'durationMs': started.elapsedMilliseconds,
        'backpressureMs': waitMs,
      });
    }
  }

  void _onMessage(RTCDataChannelMessage message) {
    if (_closed) return;
    try {
      if (!message.isBinary) {
        throw const FormatException('RTC requires CPG1 binary frames');
      }
      final envelope = _decoder.push(message.binary);
      if (envelope is! RtcClose) {
        _traffic.received(message.binary.length - rtcHeaderBytes);
      }
      final now = _diagnostics.clock.elapsedMilliseconds;
      _receivedFrames++;
      _messageFrames++;
      _messageStartedMs ??= now;
      _lastFragmentMs = now;
      if (envelope == null &&
          (_messageFrames == 1 || now - _lastProgressMs >= 1000)) {
        _lastProgressMs = now;
        _diagnostics.emit('message.receive.progress', {
          'received': _decoder.receivedBytes,
          'total': _decoder.totalBytes,
          'frames': _messageFrames,
          'durationMs': now - _messageStartedMs!,
        });
      }
      if (envelope == null) {
        // Keep the bounded partial message until complete or connection close.
        // RPC deadlines must not invalidate framing; heartbeat owns liveness.
        return;
      }
      if (_messageFrames > 1 || now - _messageStartedMs! >= 1000) {
        _diagnostics.emit('message.receive.complete', {
          'bytes': envelope is RtcJson ? envelope.bytes.length : 0,
          'frames': _messageFrames,
          'durationMs': now - _messageStartedMs!,
        });
      }
      _messageFrames = 0;
      _messageStartedMs = null;
      if (envelope is RtcClose) {
        _abort(
          GatewayConnectionException(
            'RTC closed (${envelope.code}: ${envelope.reason})',
            retryable: {1001, 1006, 1011, 1012, 1013}.contains(envelope.code),
            outcomeUnknown: true,
          ),
        );
        return;
      }
      final value = jsonDecode(utf8.decode((envelope as RtcJson).bytes));
      if (value is! Map || value['jsonrpc'] != '2.0') {
        throw const FormatException('Invalid Gateway envelope');
      }
      final json = Map<String, dynamic>.from(value);
      if (json['method'] is String && !json.containsKey('id')) {
        _events.add(json);
      } else {
        final id = json['id'];
        if (id is! String) {
          throw const FormatException('Invalid Gateway response id');
        }
        _diagnostics.emit('rpc.response', {
          'rpcId': rtcOfferId(id),
          'bytes': envelope.bytes.length,
          'isError': json.containsKey('error'),
        });
        final pending = _pending.remove(id);
        if (pending == null) {
          _diagnostics.emit('rpc.response.discarded', {
            'rpcId': rtcOfferId(id),
          });
        } else {
          pending.complete(json);
        }
      }
    } catch (error) {
      _abort(_failure(error));
    }
  }

  GatewayConnectionException _failure(Object error, {bool unknown = true}) =>
      error is GatewayConnectionException
      ? error
      : GatewayConnectionException(
          'RTC connection failed: $error',
          retryable: error is! FormatException && error is! HandshakeException,
          outcomeUnknown: unknown,
        );

  void _abort(GatewayConnectionException error) {
    if (_closed) return;
    _aborted = true;
    final now = _diagnostics.clock.elapsedMilliseconds;
    _diagnostics.emit('channel.abort', {
      'errorType': error.runtimeType.toString(),
      'cause': 'transportFailure',
      'pendingRequests': _pending.length,
      'queuedBytes': _queuedBytes,
      'receivedFrames': _receivedFrames,
      'partialReceived': _decoder.receivedBytes,
      'partialTotal': _decoder.totalBytes,
      'partialFrames': _messageFrames,
      'partialAgeMs': _messageStartedMs == null
          ? null
          : now - _messageStartedMs!,
      'lastFragmentAgeMs': _lastFragmentMs == null
          ? null
          : now - _lastFragmentMs!,
    });
    _events.addError(error);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    // close() retains the failed future for the owner's subsequent await.
    // Cleanup diagnostics are emitted at the failing native operation.
    unawaited(close().catchError((Object _) {}));
  }

  Future<T> _createOwned<T>(
    Future<T> Function() create,
    void Function(T) store,
    Future<void> Function(T) release,
  ) async {
    final value = await create();
    if (_closed) {
      await release(value);
      _checkNotClosed();
    }
    store(value);
    return value;
  }

  Future<void> _cleanupStep(
    String step,
    Future<void> Function() action,
    List<String> failures,
  ) async {
    final started = Stopwatch()..start();
    try {
      await action().timeout(cleanupTimeout);
    } catch (error) {
      failures.add(step);
      _diagnostics.emit('cleanup.failed', {
        'step': step,
        'durationMs': started.elapsedMilliseconds,
        'errorType': error.runtimeType.toString(),
      });
    }
  }

  Future<void> _releaseNative({
    RTCDataChannel? channel,
    RTCPeerConnection? peer,
  }) async {
    final failures = <String>[];
    if (channel != null) {
      channel.onMessage = null;
      channel.onDataChannelState = null;
      await _cleanupStep('channel.close', channel.close, failures);
    }
    if (peer != null) {
      peer.onConnectionState = null;
      peer.onIceGatheringState = null;
      peer.onIceConnectionState = null;
      peer.onIceCandidate = null;
      peer.onSignalingState = null;
      // Always attempt disposal, even when channel/peer close fails or hangs.
      await _cleanupStep('peer.close', peer.close, failures);
      await _cleanupStep('peer.dispose', peer.dispose, failures);
      // Successful native disposal releases the peer and all of its channels.
      // Earlier close errors remain diagnostic, but must not consume a permit
      // forever once final resource release has actually been confirmed.
      if (!failures.contains('peer.dispose')) {
        if (failures.isNotEmpty) {
          _diagnostics.emit('cleanup.recovered', {'steps': failures});
        }
        return;
      }
    }
    if (failures.isNotEmpty) throw RtcCleanupException(failures);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _statsTimer?.cancel();
    await _sampleStats('closing');
    _diagnostics.emit('channel.close');
    final failures = <String>[];
    if (signaling is RtcIceSignaling) {
      await _cleanupStep('signaling.close', () async {
        (signaling as RtcIceSignaling).close();
      }, failures);
    }
    _connected = false;
    if (_gathered != null && !_gathered!.isCompleted) {
      _gathered!.complete();
    }
    _gathered = null;
    _decoder.clear();
    for (final pending in _pending.values) {
      if (!pending.isCompleted) {
        pending.completeError(
          const GatewayConnectionException(
            'RTC connection closed',
            outcomeUnknown: true,
          ),
        );
      }
    }
    _pending.clear();
    // A cancelled native create can finish after cancellation. Its owner closes
    // the late result; do not advertise resource release before that settles.
    final creating = _creating;
    if (creating != null) {
      await _cleanupStep('creation.settle', () async {
        try {
          await creating;
        } catch (error) {
          if (error is RtcCleanupException) rethrow;
          // Creation failed, or was cancelled after successful late cleanup.
        }
      }, failures);
    }
    final channel = _channel;
    final peer = _peer;
    _channel = null;
    _peer = null;
    try {
      await _releaseNative(channel: channel, peer: peer);
    } on RtcCleanupException catch (error) {
      failures.addAll(error.steps);
    }
    await _events.close();
    _diagnostics.emit('cleanup.completed', {'confirmed': failures.isEmpty});
    if (failures.isNotEmpty) throw RtcCleanupException(failures);
  }
}
