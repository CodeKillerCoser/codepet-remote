import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../application/errors/application_failures.dart';
import '../../core/domain/models.dart';
import '../transport.dart';
import 'framing.dart';
import 'rtc_diagnostics.dart';
import 'signaling.dart';

typedef RtcPeerFactory = Future<RTCPeerConnection> Function();

/// Carries unchanged Gateway JSON-RPC over a reliable, ordered DataChannel.
final class WebRtcGatewayTransport implements GatewayTransport {
  // Public peerFactory name is retained for existing callers.
  WebRtcGatewayTransport({
    required this.signaling,
    RtcPeerFactory? peerFactory,
    this.connectTimeout = const Duration(seconds: 25),
    this.requestTimeout = const Duration(seconds: 15),
    // ignore: prefer_initializing_formals
  }) : _peerFactory = peerFactory;

  final RtcSignaling signaling;
  final RtcPeerFactory? _peerFactory;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final _events = StreamController<JsonMap>.broadcast();
  final _pending = <String, Completer<Object?>>{};
  final _decoder = RtcDecoder();
  final _diagnostics = RtcDiagnostics();
  Timer? _statsTimer;
  bool _sampling = false;
  int _statsSamples = 0;
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
      _diagnostics.emit('ice.stats', {
        'reason': reason,
        'count': relevant.length,
        'truncated': relevant.length > 128,
        'reports': relevant
            .take(128)
            .map(
              (r) =>
                  rtcStat(r, _diagnostics.offerId ?? _diagnostics.connectionId),
            )
            .toList(),
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
  Future<void> _sendTail = Future<void>.value();
  Timer? _fragmentTimer;
  Completer<void>? _gathered;
  bool _closed = false;
  bool _connected = false;
  int _queuedBytes = 0;

  @override
  Stream<JsonMap> get events => _events.stream;

  /// Report only the selected ICE route; configured TURN servers are not proof.
  Future<String> selectedPathKind() async {
    final reports = await _peer?.getStats() ?? [];
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
      if (local != null && remote != null) return 'direct';
    }
    return 'unknown';
  }

  @override
  Future<void> connect() => _connecting ??= _connect();

  Future<void> _connect() async {
    try {
      await _open().timeout(connectTimeout);
    } catch (error) {
      _diagnostics.emit('connect.failed', {
        'errorType': error.runtimeType.toString(),
      });
      await close();
      throw _failure(error, unknown: false);
    }
  }

  Future<void> _open() async {
    _diagnostics.emit('connect.start');
    _checkNotClosed();
    final config = signaling is RtcIceSignaling
        ? await (signaling as RtcIceSignaling).configuration()
        : <String, dynamic>{'iceServers': <Object>[]};
    _checkNotClosed();
    final peer = await (_peerFactory?.call() ?? createPeerConnection(config));
    if (_closed) {
      await peer.close();
      await peer.dispose();
      _checkNotClosed();
    }
    _peer = peer;
    _diagnostics.emit('ice.configuration', {
      'policy': config['iceTransportPolicy'] ?? 'all',
      'serverCount': (config['iceServers'] as List?)?.length ?? 0,
      'candidateErrorCallback': 'notExposedByFlutterWebrtc',
    });
    _statsTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _statsSamples++;
      if (!_connected || _statsSamples <= 30 || _statsSamples % 15 == 0) {
        unawaited(_sampleStats('periodic'));
      }
    });
    peer.onIceConnectionState = (state) {
      _diagnostics.emit('ice.state', {'state': state.name});
      unawaited(_sampleStats('iceState'));
    };
    peer.onSignalingState = (state) =>
        _diagnostics.emit('signaling.state', {'state': state.name});
    peer.onIceCandidate = (candidate) => _diagnostics.emit(
      'ice.localCandidate',
      rtcCandidate(
        candidate.candidate ?? '',
        _diagnostics.offerId ?? _diagnostics.connectionId,
      ),
    );
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
        gathered.complete();
      }
    };
    final channel = await peer.createDataChannel(
      'codepet.gateway.v1',
      RTCDataChannelInit()
        ..ordered = true
        ..negotiated = true
        ..id = 0
        ..protocol = 'codepet.gateway.cpg1',
    );
    if (_closed) {
      await channel.close();
      _checkNotClosed();
    }
    _channel = channel;
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
    final offer = await peer.createOffer({
      'mandatory': {'OfferToReceiveAudio': false, 'OfferToReceiveVideo': false},
      'optional': <Object>[],
    });
    _checkNotClosed();
    await peer.setLocalDescription(offer);
    if (await peer.getIceGatheringState() !=
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      await gathered.future;
    }
    _gathered = null;
    _checkNotClosed();
    final description = await peer.getLocalDescription();
    if (description?.sdp == null) {
      throw const FormatException('Missing RTC offer');
    }
    _diagnostics.offerId = rtcOfferId(description!.sdp!);
    _diagnostics.description('localOffer', description.sdp!);
    _diagnostics.emit('signaling.offer.start');
    final answer = await signaling.answer({
      'type': 'offer',
      'sdp': description.sdp,
    });
    _checkNotClosed();
    if (answer['type'] != 'answer' || answer['sdp'] is! String) {
      throw const FormatException('Invalid RTC answer');
    }
    _diagnostics.emit('signaling.answer.received');
    _diagnostics.description('remoteAnswer', answer['sdp'] as String);
    await peer.setRemoteDescription(
      RTCSessionDescription(answer['sdp'] as String, 'answer'),
    );
    while (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      _checkNotClosed();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _connected = true;
    _diagnostics.emit('channel.open');
    unawaited(_sampleStats('open'));
  }

  void _checkNotClosed() {
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
        request['method'] is! String ||
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
            // A timed-out partially sent message cannot be followed by another message.
            _abort(error);
            throw error;
          },
        )
        .whenComplete(() {
          _pending.remove(id);
        });
    _sendTail = _sendTail.then((_) async {
      try {
        if (!_closed && _pending.containsKey(id)) {
          await _send(bytes).timeout(requestTimeout);
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
    var waitMs = 0;
    _diagnostics.emit('message.send.start', {'bytes': bytes.length});
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
          ),
        ),
      );
      offset = end;
    }
    _diagnostics.emit('message.send.complete', {
      'bytes': bytes.length,
      'durationMs': started.elapsedMilliseconds,
      'backpressureMs': waitMs,
    });
  }

  void _onMessage(RTCDataChannelMessage message) {
    if (_closed) return;
    try {
      if (!message.isBinary) {
        throw const FormatException('RTC requires CPG1 binary frames');
      }
      final envelope = _decoder.push(message.binary);
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
        _fragmentTimer ??= Timer(
          const Duration(seconds: 5),
          () => _abort(
            const GatewayConnectionException(
              'RTC fragment timed out',
              retryable: true,
              outcomeUnknown: true,
            ),
          ),
        );
        return;
      }
      _diagnostics.emit('message.receive.complete', {
        'bytes': envelope is RtcJson ? envelope.bytes.length : 0,
        'frames': _messageFrames,
        'durationMs': now - _messageStartedMs!,
      });
      _messageFrames = 0;
      _messageStartedMs = null;
      _fragmentTimer?.cancel();
      _fragmentTimer = null;
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
        _pending.remove(id)?.complete(json);
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
    final now = _diagnostics.clock.elapsedMilliseconds;
    _diagnostics.emit('channel.abort', {
      'errorType': error.runtimeType.toString(),
      'cause': error.message == 'RTC fragment timed out'
          ? 'fragmentTimeout'
          : 'transportFailure',
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
    unawaited(close());
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    _statsTimer?.cancel();
    await _sampleStats('closing');
    _diagnostics.emit('channel.close');
    if (signaling is RtcIceSignaling) (signaling as RtcIceSignaling).close();
    _connected = false;
    _fragmentTimer?.cancel();
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
    final channel = _channel;
    final peer = _peer;
    _channel = null;
    _peer = null;
    if (channel != null) {
      channel.onMessage = null;
      channel.onDataChannelState = null;
      try {
        await channel.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    if (peer != null) {
      peer.onConnectionState = null;
      peer.onIceGatheringState = null;
      peer.onIceConnectionState = null;
      peer.onIceCandidate = null;
      peer.onSignalingState = null;
      try {
        await peer.close().timeout(const Duration(seconds: 2));
      } catch (_) {}
      try {
        await peer.dispose().timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    await _events.close();
  }
}
