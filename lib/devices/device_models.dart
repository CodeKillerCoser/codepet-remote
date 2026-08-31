import '../gateway/models.dart';

enum DeviceConnectionKind { pairedGateway, developmentGateway, demo }

class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.displayName,
    required this.connectionKind,
    this.alias,
    this.tlsFingerprint,
    this.endpointHints = const [],
    this.credentialKeyRef,
    this.clientId,
    this.preferredEndpoint,
    this.autoConnect = false,
  });

  final String deviceId;
  final String displayName;
  final String? alias;
  final String? tlsFingerprint;
  final List<String> endpointHints;
  final String? credentialKeyRef;
  final String? clientId;
  final String? preferredEndpoint;
  final bool autoConnect;
  final DeviceConnectionKind connectionKind;

  String get effectiveName => alias?.trim().isNotEmpty == true ? alias! : displayName;

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'alias': alias,
        'tlsFingerprint': tlsFingerprint,
        'endpointHints': endpointHints,
        'credentialKeyRef': credentialKeyRef,
        'clientId': clientId,
        'preferredEndpoint': preferredEndpoint,
        'autoConnect': autoConnect,
        'connectionKind': connectionKind.name,
      };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
    deviceId: json['deviceId'] as String,
    displayName: json['displayName'] as String,
    alias: json['alias'] as String?,
    tlsFingerprint: json['tlsFingerprint'] as String?,
    endpointHints: (json['endpointHints'] as List? ?? const []).cast<String>(),
    credentialKeyRef: json['credentialKeyRef'] as String?,
    clientId: json['clientId'] as String?,
    preferredEndpoint: json['preferredEndpoint'] as String?,
    autoConnect: json['autoConnect'] == true,
    connectionKind: DeviceConnectionKind.values.byName(json['connectionKind'] as String),
  );
}

abstract interface class PairingService {
  Future<PairedDevice> pairFromQr(String qrPayload);
}

class PairingUnavailableException implements Exception {
  const PairingUnavailableException();

  @override
  String toString() => '正式 Gateway v1 与 QR 配对尚未落地。';
}

class UnavailablePairingService implements PairingService {
  const UnavailablePairingService();

  @override
  Future<PairedDevice> pairFromQr(String qrPayload) {
    throw const PairingUnavailableException();
  }
}

class DevelopmentConnection {
  const DevelopmentConnection({required this.device, required this.connection});

  final PairedDevice device;
  final DeviceConnection connection;
}
