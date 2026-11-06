import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:logging/logging.dart';

import '../../diagnostics/app_log.dart';
import '../../application/errors/application_failures.dart';

String rtcOfferId(String sdp) =>
    sha256.convert(utf8.encode(sdp)).toString().substring(0, 24);

/// Addresses are pseudonymous within an offer, never raw SDP or ICE credentials.
Map<String, Object?> rtcAddress(String address, String salt) {
  final ip = InternetAddress.tryParse(address);
  final bytes = ip?.rawAddress;
  final scope = ip == null
      ? 'hostname'
      : ip.isLoopback
      ? 'loopback'
      : ip.isLinkLocal
      ? 'linkLocal'
      : bytes!.length == 4 &&
            (bytes[0] == 10 ||
                (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
                (bytes[0] == 192 && bytes[1] == 168))
      ? 'private'
      : bytes.length == 4 &&
            bytes[0] == 100 &&
            bytes[1] >= 64 &&
            bytes[1] <= 127
      ? 'cgnat'
      : bytes.length == 4 &&
            bytes[0] == 198 &&
            (bytes[1] == 18 || bytes[1] == 19)
      ? 'benchmarkTun'
      : bytes.length == 16 && (bytes[0] & 0xfe) == 0xfc
      ? 'private'
      : 'public';
  return {
    'scope': scope,
    'family': ip?.type.name ?? 'hostname',
    'addressId': rtcOfferId('$salt:$address'),
  };
}

Map<String, Object?> rtcCandidate(String line, String salt) {
  final fields = line
      .trim()
      .replaceFirst(RegExp(r'^a='), '')
      .split(RegExp(r'\s+'));
  if (fields.length < 8 || !fields.first.startsWith('candidate:')) {
    return {'valid': false};
  }
  String? extra(String key) {
    final index = fields.indexOf(key, 8);
    return index >= 0 && index + 1 < fields.length ? fields[index + 1] : null;
  }

  String safe(String value) =>
      RegExp(r'^[a-zA-Z0-9_-]{1,32}$').hasMatch(value) ? value : 'unknown';
  return {
    'component': int.tryParse(fields[1]),
    'protocol': safe(fields[2]),
    'priority': int.tryParse(fields[3]),
    ...rtcAddress(fields[4], salt),
    'port': int.tryParse(fields[5]),
    'candidateType': safe(fields[7]),
    if (extra('tcptype') != null) 'tcpType': safe(extra('tcptype')!),
    if (extra('network-id') != null)
      'networkId': int.tryParse(extra('network-id')!),
    if (extra('network-cost') != null)
      'networkCost': int.tryParse(extra('network-cost')!),
  };
}

const rtcStatFields = {
  'state',
  'nominated',
  'selected',
  'localCandidateId',
  'remoteCandidateId',
  'selectedCandidatePairId',
  'candidateType',
  'protocol',
  'networkType',
  'relayProtocol',
  'port',
  'priority',
  'bytesSent',
  'bytesReceived',
  'packetsSent',
  'packetsReceived',
  'requestsSent',
  'requestsReceived',
  'responsesSent',
  'responsesReceived',
  'consentRequestsSent',
  'currentRoundTripTime',
  'totalRoundTripTime',
  'availableOutgoingBitrate',
  'packetsDiscardedOnSend',
  'bytesDiscardedOnSend',
  'dtlsState',
  'iceRole',
  'messagesSent',
  'messagesReceived',
  'dataChannelIdentifier',
};

Map<String, Object?> rtcStat(StatsReport report, String salt) => {
  'id': report.id,
  'type': report.type,
  for (final entry in report.values.entries)
    if (rtcStatFields.contains(entry.key) &&
        (entry.value is num || entry.value is bool || entry.value is String))
      entry.key: entry.value is String
          ? (entry.value as String).substring(
              0,
              (entry.value as String).length.clamp(0, 128),
            )
          : entry.value,
  if (report.values['address'] is String || report.values['ip'] is String)
    ...rtcAddress(
      (report.values['address'] ?? report.values['ip']) as String,
      salt,
    ),
};

final class RtcDiagnostics {
  RtcDiagnostics({this.raceId, this.pathPolicy})
    : connectionId =
          'remote-${DateTime.now().microsecondsSinceEpoch}-${_sequence++}';
  static int _sequence = 0;
  final String connectionId;
  String? offerId;
  String? raceId;
  final String? pathPolicy;
  final clock = Stopwatch()..start();
  void emit(String event, [Map<String, Object?> fields = const {}]) {
    AppLog.named('gateway.rtc.diagnostic').event(
      event, {
        'schema': 'codepet.rtc.v1',
        'connectionId': connectionId,
        'timestampUnixMs': DateTime.now().millisecondsSinceEpoch,
        if (raceId != null) 'raceId': raceId,
        if (pathPolicy != null) 'pathPolicy': pathPolicy,
        if (offerId != null) 'offerId': offerId,
        'elapsedMs': clock.elapsedMilliseconds,
        ...fields,
      },
      level: event.endsWith('.failed') || fields['outcome'] == 'failed'
          ? Level.WARNING
          : const {'ice.stats', 'ice.localCandidate'}.contains(event)
              ? Level.FINE : Level.INFO,
    );
  }

  void description(String side, String sdp) {
    final lines = sdp
        .split('\n')
        .where((line) => line.trim().startsWith('a=candidate:'))
        .toList();
    emit('ice.description', {
      'side': side,
      'bytes': utf8.encode(sdp).length,
      'candidateCount': lines.length,
      'truncated': lines.length > 128,
      'candidates': lines
          .take(128)
          .map((line) => rtcCandidate(line, offerId ?? connectionId))
          .toList(),
    });
  }
}

/// Classify errors without copying native messages, URLs, tokens or SDP.
Map<String, Object?> rtcFailure(Object error) {
  var cause = 'unknown';
  int? status;
  if (error is TimeoutException) {
    cause = 'timeout';
  } else if (error is HandshakeException) {
    cause = 'tlsHandshake';
  } else if (error is SocketException) {
    cause = 'socket';
  } else if (error is FormatException) {
    cause = switch (error.message) {
      'Cloud peer signature rejected' => 'peerSignatureRejected',
      'Cloud answer binding rejected' => 'answerBindingRejected',
      _ => 'invalidDataOrSignature',
    };
  } else if (error is GatewayConnectionException) {
    cause = 'gatewayConnection';
    if (error.message == '尚无公网通道授权，请扫描新版 Host 的配对二维码。') {
      cause = 'cloudAuthorizationMissing';
    }
    if (error.message.startsWith('No ICE candidates for ')) {
      cause = 'noCandidates';
    }
    if (error.message == 'Cloud answer timed out') cause = 'answerTimeout';
    if (error.message == 'RTC peer closed') cause = 'peerClosed';
    if (error.message == 'RTC channel closed') cause = 'channelClosed';
    final match = RegExp(r'^Cloud signaling status (\d{3})$')
        .firstMatch(error.message);
    if (match != null) {
      cause = 'httpStatus';
      status = int.parse(match[1]!);
    }
  }
  return {
    'cause': cause,
    'errorType': error.runtimeType.toString(),
    'retryable': isRetryableGatewayFailure(error),
    'status': ?status,
    if (error is SocketException) 'osErrorCode': error.osError?.errorCode,
  };
}
