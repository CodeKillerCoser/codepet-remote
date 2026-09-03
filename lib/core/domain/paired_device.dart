import 'models.dart';

enum DeviceConnectionKind { pairedGateway, demo }

class PairedDevice {
  const PairedDevice({
    required this.deviceId,
    required this.displayName,
    required this.connectionKind,
    this.alias,
    this.descriptor,
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
  final DeviceDescriptor? descriptor;
  final String? tlsFingerprint;
  /// Untrusted or previously validated network locators, never device identity.
  final List<String> endpointHints;
  final String? credentialKeyRef;
  final String? clientId;
  /// The last Host-authorized or validated locator, never device identity.
  final String? preferredEndpoint;
  final bool autoConnect;
  final DeviceConnectionKind connectionKind;

  String get effectiveName =>
      alias?.trim().isNotEmpty == true ? alias! : displayName;

  PairedDevice withPreferredEndpoint(String endpoint) => PairedDevice(
        deviceId: deviceId,
        displayName: displayName,
        connectionKind: connectionKind,
        alias: alias,
        descriptor: descriptor,
        tlsFingerprint: tlsFingerprint,
        endpointHints: endpointHints,
        credentialKeyRef: credentialKeyRef,
        clientId: clientId,
        preferredEndpoint: endpoint,
        autoConnect: autoConnect,
      );

  PairedDevice withDescriptor(DeviceDescriptor value) => PairedDevice(
        deviceId: deviceId,
        displayName: value.deviceName,
        connectionKind: connectionKind,
        alias: alias,
        descriptor: value,
        tlsFingerprint: tlsFingerprint,
        endpointHints: endpointHints,
        credentialKeyRef: credentialKeyRef,
        clientId: clientId,
        preferredEndpoint: preferredEndpoint,
        autoConnect: autoConnect,
      );

  Map<String, Object?> toJson() => {
        'deviceId': deviceId,
        'displayName': displayName,
        'alias': alias,
        'descriptor': descriptor?.toJson(),
        'tlsFingerprint': tlsFingerprint,
        'endpointHints': endpointHints,
        'credentialKeyRef': credentialKeyRef,
        'clientId': clientId,
        'preferredEndpoint': preferredEndpoint,
        'autoConnect': autoConnect,
        'connectionKind': connectionKind.name,
      };

  factory PairedDevice.fromJson(Map<String, dynamic> json) {
    final descriptor = json['descriptor'];
    return PairedDevice(
      deviceId: json['deviceId'] as String,
      displayName: json['displayName'] as String,
      alias: json['alias'] as String?,
      descriptor: descriptor is Map
          ? DeviceDescriptor.fromJson(Map<String, dynamic>.from(descriptor))
          : null,
      tlsFingerprint: json['tlsFingerprint'] as String?,
      endpointHints: (json['endpointHints'] as List? ?? const []).cast<String>(),
      credentialKeyRef: json['credentialKeyRef'] as String?,
      clientId: json['clientId'] as String?,
      preferredEndpoint: json['preferredEndpoint'] as String?,
      autoConnect: json['autoConnect'] == true,
      connectionKind: _connectionKindFromJson(json['connectionKind'] as String),
    );
  }
}

DeviceConnectionKind _connectionKindFromJson(String value) =>
    value == 'developmentGateway'
        ? DeviceConnectionKind.pairedGateway
        : DeviceConnectionKind.values.byName(value);
