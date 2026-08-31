import 'models.dart';

const gatewayV1 = 1;

class RoutedResourceId {
  const RoutedResourceId({required this.deviceId, required this.providerPluginId, required this.providerInstanceId, required this.nativeResourceId});
  factory RoutedResourceId.fromJson(JsonMap json) => RoutedResourceId(
    deviceId: _string(json, 'deviceId'), providerPluginId: _string(json, 'providerPluginId'),
    providerInstanceId: _string(json, 'providerInstanceId'), nativeResourceId: _string(json, 'nativeResourceId'),
  );
  final String deviceId;
  final String providerPluginId;
  final String providerInstanceId;
  final String nativeResourceId;
  JsonMap toJson() => {'deviceId': deviceId, 'providerPluginId': providerPluginId, 'providerInstanceId': providerInstanceId, 'nativeResourceId': nativeResourceId};
  String get key => '$deviceId\u0000$providerPluginId\u0000$providerInstanceId\u0000$nativeResourceId';
}

class V1HostIdentity {
  const V1HostIdentity({required this.deviceId, required this.displayName, required this.identityFingerprint});
  factory V1HostIdentity.fromJson(JsonMap json) => V1HostIdentity(deviceId: _string(json, 'deviceId'), displayName: _string(json, 'displayName'), identityFingerprint: _fingerprint(json, 'identityFingerprint'));
  final String deviceId;
  final String displayName;
  final String identityFingerprint;
}

class V1Handshake {
  const V1Handshake({required this.selectedVersion, required this.serverName, required this.serverVersion, required this.device, required this.eventCursor, required this.providers});
  factory V1Handshake.fromJson(JsonMap json) => V1Handshake(
    selectedVersion: _int(json, 'selectedVersion'), serverName: _string(json, 'serverName'), serverVersion: _string(json, 'serverVersion'),
    device: V1HostIdentity.fromJson(_map(json, 'device')), eventCursor: _string(json, 'eventCursor'),
    providers: _maps(json, 'providers'),
  );
  final int selectedVersion;
  final String serverName;
  final String serverVersion;
  final V1HostIdentity device;
  final String eventCursor;
  final List<JsonMap> providers;
}

class V1Conversation {
  const V1Conversation({required this.resource, required this.title, required this.status, this.permissionLevel, this.preview, this.model, this.reasoningEffort, this.workspaceRoot, this.createdAt, this.updatedAt});
  factory V1Conversation.fromJson(JsonMap json) => V1Conversation(
    resource: RoutedResourceId.fromJson(_map(json, 'resource')), title: _string(json, 'title'), status: _string(json, 'status'),
    permissionLevel: _optionalString(json, 'permissionLevel'), preview: _optionalString(json, 'preview'), model: _optionalString(json, 'model'),
    reasoningEffort: _optionalString(json, 'reasoningEffort'), workspaceRoot: _optionalString(json, 'workspaceRoot'),
    createdAt: _optionalTime(json, 'createdAt'), updatedAt: _optionalTime(json, 'updatedAt'),
  );
  final RoutedResourceId resource;
  final String title;
  final String status;
  final String? permissionLevel;
  final String? preview;
  final String? model;
  final String? reasoningEffort;
  final String? workspaceRoot;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  ConversationSummary toDomain() => ConversationSummary(
    id: resource.key,
    providerId: resource.providerInstanceId,
    title: title,
    preview: preview,
    status: ConversationStatus.values.firstWhere((value) => value.wireValue == status, orElse: () => ConversationStatus.error),
    permissionLevel: PermissionLevel.values.firstWhere((value) => value.wireValue == permissionLevel, orElse: () => PermissionLevel.readOnly),
    model: model, reasoningEffort: reasoningEffort, workspaceRoot: workspaceRoot,
    createdAt: createdAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt: updatedAt ?? createdAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    wireResource: resource.toJson(),
  );
}

String _string(JsonMap json, String field) {
  final value = json[field];
  if (value is! String || value.isEmpty) throw FormatException('Expected non-empty $field');
  return value;
}
String _fingerprint(JsonMap json, String field) {
  final value = _string(json, field);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) throw FormatException('Invalid $field');
  return value;
}
String? _optionalString(JsonMap json, String field) => json[field] == null ? null : _string(json, field);
int _int(JsonMap json, String field) { final value = json[field]; if (value is! int) throw FormatException('Expected integer $field'); return value; }
JsonMap _map(JsonMap json, String field) { final value = json[field]; if (value is! Map) throw FormatException('Expected object $field'); return Map<String, dynamic>.from(value); }
List<JsonMap> _maps(JsonMap json, String field) { final value = json[field]; if (value is! List) throw FormatException('Expected array $field'); return value.map((item) => Map<String, dynamic>.from(item as Map)).toList(growable: false); }
DateTime? _optionalTime(JsonMap json, String field) { final value = json[field]; if (value == null) return null; if (value is! int) throw FormatException('Expected timestamp $field'); return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true); }
