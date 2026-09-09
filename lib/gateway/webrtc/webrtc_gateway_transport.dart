import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../application/errors/application_failures.dart';
import '../../core/domain/models.dart';
import '../transport.dart';
import 'framing.dart';
import 'signaling.dart';

typedef RtcPeerFactory = Future<RTCPeerConnection> Function();

/// Carries unchanged Gateway JSON-RPC over a reliable, ordered DataChannel.
final class WebRtcGatewayTransport implements GatewayTransport {
  WebRtcGatewayTransport({
    required this.signaling,
    RtcPeerFactory? peerFactory,
    this.connectTimeout = const Duration(seconds: 25),
    this.requestTimeout = const Duration(seconds: 15),
  }) : _peerFactory =
           peerFactory ??
           (() => createPeerConnection({'iceServers': <Object>[]}));

  final RtcSignaling signaling;
  final RtcPeerFactory _peerFactory;
  final Duration connectTimeout;
  final Duration requestTimeout;
  final _events = StreamController<JsonMap>.broadcast();
  final _pending = <String, Completer<Object?>>{};
  final _decoder = RtcDecoder();
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

  @override
  Future<void> connect() => _connecting ??= _connect();

  Future<void> _connect() async {
    try {
      await _open().timeout(connectTimeout);
    } catch (error) {
      await close();
      throw _failure(error, unknown: false);
    }
  }

  Future<void> _open() async {
    _checkNotClosed();
    final peer = await _peerFactory();
    if (_closed) {
      await peer.close();
      await peer.dispose();
      _checkNotClosed();
    }
    _peer = peer;
    peer.onConnectionState = (state) {
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
    final answer = await signaling.answer({
      'type': 'offer',
      'sdp': description!.sdp,
    });
    _checkNotClosed();
    if (answer['type'] != 'answer' || answer['sdp'] is! String) {
      throw const FormatException('Invalid RTC answer');
    }
    await peer.setRemoteDescription(
      RTCSessionDescription(answer['sdp'] as String, 'answer'),
    );
    while (channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      _checkNotClosed();
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    _connected = true;
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
    for (var offset = 0; offset < bytes.length;) {
      _checkNotClosed();
      if (await channel.getBufferedAmount() > 64 * 1024) {
        while (await channel.getBufferedAmount() > 16 * 1024) {
          _checkNotClosed();
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
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
  }

  void _onMessage(RTCDataChannelMessage message) {
    if (_closed) return;
    try {
      if (!message.isBinary) {
        throw const FormatException('RTC requires CPG1 binary frames');
      }
      final envelope = _decoder.push(message.binary);
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
