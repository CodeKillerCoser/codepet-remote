import 'models.dart';

const gatewayV1 = 1;

class RoutedResourceId {
  const RoutedResourceId({
    required this.deviceId,
    required this.providerPluginId,
    required this.providerInstanceId,
    required this.nativeResourceId,
  });

  factory RoutedResourceId.fromJson(JsonMap json) {
    _fields(
      json,
      const {
        'deviceId',
        'providerPluginId',
        'providerInstanceId',
        'nativeResourceId',
      },
    );
    return RoutedResourceId(
      deviceId: _string(json, 'deviceId'),
      providerPluginId: _string(json, 'providerPluginId'),
      providerInstanceId: _string(json, 'providerInstanceId'),
      nativeResourceId: _string(json, 'nativeResourceId'),
    );
  }

  final String deviceId;
  final String providerPluginId;
  final String providerInstanceId;
  final String nativeResourceId;

  JsonMap toJson() => {
        'deviceId': deviceId,
        'providerPluginId': providerPluginId,
        'providerInstanceId': providerInstanceId,
        'nativeResourceId': nativeResourceId,
      };

  String get key =>
      '$deviceId\u0000$providerPluginId\u0000$providerInstanceId\u0000$nativeResourceId';

  bool hasRouteOf(RoutedResourceId other) =>
      deviceId == other.deviceId &&
      providerPluginId == other.providerPluginId &&
      providerInstanceId == other.providerInstanceId;
}

class V1HostIdentity {
  const V1HostIdentity({
    required this.deviceId,
    required this.descriptor,
    required this.identityFingerprint,
  });

  factory V1HostIdentity.fromJson(JsonMap json) {
    _fields(
      json,
      const {'deviceId', 'descriptor', 'identityFingerprint'},
    );
    return V1HostIdentity(
      deviceId: _string(json, 'deviceId'),
      descriptor: DeviceDescriptor.fromJson(_map(json, 'descriptor')),
      identityFingerprint: _fingerprint(json, 'identityFingerprint'),
    );
  }

  final String deviceId;
  final DeviceDescriptor descriptor;
  final String identityFingerprint;
}

class V1Handshake {
  const V1Handshake({
    required this.selectedVersion,
    required this.serverName,
    required this.serverVersion,
    required this.device,
    required this.eventCursor,
    required this.providers,
    required this.devices,
  });

  factory V1Handshake.fromJson(JsonMap json) {
    _fields(
      json,
      const {
        'selectedVersion',
        'serverName',
        'serverVersion',
        'device',
        'devices',
        'providers',
        'eventCursor',
      },
    );
    return V1Handshake(
      selectedVersion: _int(json, 'selectedVersion'),
      serverName: _string(json, 'serverName'),
      serverVersion: _string(json, 'serverVersion'),
      device: V1HostIdentity.fromJson(_map(json, 'device')),
      eventCursor: _string(json, 'eventCursor'),
      providers: _maps(json, 'providers'),
      devices: _maps(json, 'devices'),
    );
  }

  final int selectedVersion;
  final String serverName;
  final String serverVersion;
  final V1HostIdentity device;
  final String eventCursor;
  final List<JsonMap> providers;
  final List<JsonMap> devices;
}

class V1Conversation {
  const V1Conversation({
    required this.resource,
    required this.title,
    required this.status,
    this.permissionLevel,
    this.preview,
    this.model,
    this.reasoningEffort,
    this.workspaceRoot,
    this.createdAt,
    this.updatedAt,
    this.activeTurn,
    this.turnSendSelection,
  });

  factory V1Conversation.fromJson(JsonMap json) {
    _fields(
      json,
      const {'resource', 'title', 'status'},
      optional: const {
        'preview',
        'permissionLevel',
        'model',
        'reasoningEffort',
        'workspaceRoot',
        'createdAt',
        'updatedAt',
        'activeTurn',
        'selection',
      },
    );
    return V1Conversation(
      resource: RoutedResourceId.fromJson(_map(json, 'resource')),
      title: _string(json, 'title'),
      status: _enumString(json, 'status', const {
        'idle',
        'running',
        'waiting-approval',
        'waiting-user-input',
        'error',
        'archived',
      }),
      permissionLevel: _optionalString(json, 'permissionLevel'),
      preview: _optionalString(json, 'preview', allowEmpty: true),
      model: _optionalString(json, 'model', allowEmpty: true),
      reasoningEffort:
          _optionalString(json, 'reasoningEffort', allowEmpty: true),
      workspaceRoot: _optionalString(json, 'workspaceRoot'),
      createdAt: _optionalTime(json, 'createdAt'),
      updatedAt: _optionalTime(json, 'updatedAt'),
      activeTurn: json['activeTurn'] == null
          ? null
          : V1TurnTask.fromJson(_map(json, 'activeTurn')),
      turnSendSelection: json['selection'] == null
          ? null
          : TurnSendSelection.fromJson(_map(json, 'selection')),
    );
  }

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
  final V1TurnTask? activeTurn;
  final TurnSendSelection? turnSendSelection;

  ConversationSummary toDomain() => ConversationSummary(
        id: resource.key,
        providerId: resource.providerInstanceId,
        title: title,
        preview: preview,
        status: ConversationStatus.values.firstWhere(
          (value) => value.wireValue == status,
          orElse: () => ConversationStatus.error,
        ),
        permissionLevel: PermissionLevel.values.firstWhere(
          (value) => value.wireValue == permissionLevel,
          orElse: () => PermissionLevel.readOnly,
        ),
        model: model,
        reasoningEffort: reasoningEffort,
        workspaceRoot: workspaceRoot,
        createdAt:
            createdAt ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        updatedAt: updatedAt ??
            createdAt ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        activeTurn: activeTurn?.toDomain(),
        turnSendSelection: turnSendSelection,
        wireResource: resource.toJson(),
      );
}

class V1TurnTask {
  const V1TurnTask({
    required this.resource,
    required this.conversation,
    required this.status,
    this.displaySummary,
    this.startedAt,
    this.updatedAt,
    this.completedAt,
  });

  factory V1TurnTask.fromJson(JsonMap json) {
    _fields(
      json,
      const {'resource', 'conversation', 'status'},
      optional: const {
        'displaySummary',
        'startedAt',
        'updatedAt',
        'completedAt',
      },
    );
    return V1TurnTask(
      resource: RoutedResourceId.fromJson(_map(json, 'resource')),
      conversation: RoutedResourceId.fromJson(_map(json, 'conversation')),
      status: _enumString(json, 'status', const {
        'queued',
        'running',
        'waiting-approval',
        'completed',
        'failed',
        'interrupted',
      }),
      displaySummary: _optionalString(
        json,
        'displaySummary',
        allowEmpty: true,
      ),
      startedAt: _optionalTime(json, 'startedAt'),
      updatedAt: _optionalTime(json, 'updatedAt'),
      completedAt: _optionalTime(json, 'completedAt'),
    );
  }

  final RoutedResourceId resource;
  final RoutedResourceId conversation;
  final String status;
  final String? displaySummary;
  final DateTime? startedAt;
  final DateTime? updatedAt;
  final DateTime? completedAt;

  TurnTask toDomain() => TurnTask(
        id: resource.key,
        providerId: resource.providerInstanceId,
        conversationId: conversation.key,
        status: TurnStatus.fromWire(status),
        displaySummary: displaySummary,
        startedAt: startedAt,
        updatedAt: updatedAt ??
            startedAt ??
            DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        completedAt: completedAt,
        wireResource: resource.toJson(),
        conversationWireResource: conversation.toJson(),
      );
}

class V1ConversationContent {
  const V1ConversationContent({
    required this.contentId,
    required this.kind,
    required this.text,
  });

  factory V1ConversationContent.fromJson(JsonMap json) {
    _fields(json, const {'contentId', 'kind', 'text'});
    return V1ConversationContent(
      contentId: _string(json, 'contentId'),
      kind: _enumString(json, 'kind', const {
        'text',
        'reasoning-summary',
        'command',
        'output',
        'activity-summary',
      }),
      text: _string(json, 'text', allowEmpty: true),
    );
  }

  final String contentId;
  final String kind;
  final String text;
}

class V1Approval {
  const V1Approval({
    required this.resource,
    required this.conversation,
    required this.turn,
    required this.kind,
    required this.title,
    required this.status,
    required this.decisions,
    this.description,
    this.decision,
  });

  factory V1Approval.fromJson(JsonMap json) {
    _fields(
      json,
      const {
        'resource',
        'conversation',
        'turn',
        'kind',
        'title',
        'status',
        'decisions',
      },
      optional: const {
        'description',
        'requestedAt',
        'resolvedAt',
        'decision',
      },
    );
    _optionalTime(json, 'requestedAt');
    _optionalTime(json, 'resolvedAt');
    return V1Approval(
      resource: RoutedResourceId.fromJson(_map(json, 'resource')),
      conversation: RoutedResourceId.fromJson(_map(json, 'conversation')),
      turn: RoutedResourceId.fromJson(_map(json, 'turn')),
      kind: _string(json, 'kind'),
      title: _string(json, 'title'),
      description: _optionalString(json, 'description', allowEmpty: true),
      status: _enumString(
        json,
        'status',
        const {'pending', 'approved', 'denied', 'expired'},
      ),
      decisions: _strings(json, 'decisions', const {'approve', 'deny'}),
      decision: _optionalEnumString(
        json,
        'decision',
        const {'approve', 'deny'},
      ),
    );
  }

  final RoutedResourceId resource;
  final RoutedResourceId conversation;
  final RoutedResourceId turn;
  final String kind;
  final String title;
  final String? description;
  final String status;
  final List<String> decisions;
  final String? decision;
}

class V1ConversationItem {
  const V1ConversationItem({
    required this.resource,
    required this.turn,
    required this.conversation,
    required this.kind,
    required this.status,
    required this.contents,
    this.role,
    this.title,
    this.relatedItem,
    this.approval,
  });

  factory V1ConversationItem.fromJson(JsonMap json) {
    _fields(
      json,
      const {
        'resource',
        'turn',
        'conversation',
        'kind',
        'status',
        'contents',
      },
      optional: const {'role', 'title', 'relatedItem', 'approval'},
    );
    final relatedItem = json['relatedItem'];
    final approval = json['approval'];
    return V1ConversationItem(
      resource: RoutedResourceId.fromJson(_map(json, 'resource')),
      turn: RoutedResourceId.fromJson(_map(json, 'turn')),
      conversation: RoutedResourceId.fromJson(_map(json, 'conversation')),
      kind: _enumString(json, 'kind', const {
        'message',
        'reasoning',
        'command',
        'file-change',
        'tool',
        'approval',
        'unknown',
      }),
      status: _enumString(json, 'status', const {
        'pending',
        'running',
        'completed',
        'failed',
        'interrupted',
        'declined',
        'approved',
        'denied',
        'expired',
        'unknown',
      }),
      role: _optionalEnumString(json, 'role', const {'user', 'assistant'}),
      title: _optionalString(json, 'title'),
      contents: _maps(json, 'contents')
          .map(V1ConversationContent.fromJson)
          .toList(growable: false),
      relatedItem: relatedItem == null
          ? null
          : RoutedResourceId.fromJson(_asMap(relatedItem, 'relatedItem')),
      approval: approval == null
          ? null
          : V1Approval.fromJson(_asMap(approval, 'approval')),
    );
  }

  final RoutedResourceId resource;
  final RoutedResourceId turn;
  final RoutedResourceId conversation;
  final String kind;
  final String status;
  final String? role;
  final String? title;
  final List<V1ConversationContent> contents;
  final RoutedResourceId? relatedItem;
  final V1Approval? approval;

  GatewayMessage toDomain(int index) {
    final text = contents
        .map((content) => content.text)
        .where((value) => value.isNotEmpty)
        .join('\n');
    final fallback = approval?.description ?? title ?? status;
    return GatewayMessage(
      id: resource.key,
      itemId: resource.nativeResourceId,
      turnId: turn.key,
      role: switch (role) {
        'user' => MessageRole.user,
        'assistant' => MessageRole.assistant,
        _ => MessageRole.system,
      },
      kind: kind,
      content: text.isEmpty ? fallback : text,
      createdAt: DateTime.fromMillisecondsSinceEpoch(index, isUtc: true),
      isStreaming: false,
      contentIds:
          contents.map((content) => content.contentId).toList(growable: false),
      title: title ?? approval?.title,
      status: status,
      approvalStatus: approval?.status,
    );
  }
}

class V1TurnSendResponse {
  const V1TurnSendResponse({
    required this.accepted,
    required this.turn,
    required this.userItem,
    required this.effectiveSelection,
  });

  factory V1TurnSendResponse.fromJson(JsonMap json) {
    _fields(
      json,
      const {
        'accepted',
        'turn',
        'userItem',
        'effectiveSelection',
      },
    );
    final accepted = json['accepted'];
    if (accepted is! bool) {
      throw const FormatException('Expected boolean accepted');
    }
    return V1TurnSendResponse(
      accepted: accepted,
      turn: V1TurnTask.fromJson(_map(json, 'turn')),
      userItem: V1ConversationItem.fromJson(_map(json, 'userItem')),
      effectiveSelection: TurnSendSelection.fromJson(
        _map(json, 'effectiveSelection'),
      ),
    );
  }

  final bool accepted;
  final V1TurnTask turn;
  final V1ConversationItem userItem;
  final TurnSendSelection effectiveSelection;
}

void _fields(
  JsonMap json,
  Set<String> required, {
  Set<String> optional = const {},
}) {
  final actual = json.keys.toSet();
  if (required.difference(actual).isNotEmpty ||
      actual.difference({...required, ...optional}).isNotEmpty) {
    throw const FormatException('Gateway v1 fields do not match the schema');
  }
}

String _string(JsonMap json, String field, {bool allowEmpty = false}) {
  final value = json[field];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('Expected ${allowEmpty ? '' : 'non-empty '}$field');
  }
  return value;
}

String _fingerprint(JsonMap json, String field) {
  final value = _string(json, field);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('Invalid $field');
  }
  return value;
}

String _enumString(JsonMap json, String field, Set<String> values) {
  final value = _string(json, field);
  if (!values.contains(value)) throw FormatException('Invalid $field');
  return value;
}

String? _optionalString(
  JsonMap json,
  String field, {
  bool allowEmpty = false,
}) =>
    json[field] == null
        ? null
        : _string(json, field, allowEmpty: allowEmpty);

String? _optionalEnumString(
  JsonMap json,
  String field,
  Set<String> values,
) =>
    json[field] == null ? null : _enumString(json, field, values);

int _int(JsonMap json, String field) {
  final value = json[field];
  if (value is! int) throw FormatException('Expected integer $field');
  return value;
}

JsonMap _asMap(Object? value, String field) {
  if (value is! Map) throw FormatException('Expected object $field');
  return Map<String, dynamic>.from(value);
}

JsonMap _map(JsonMap json, String field) => _asMap(json[field], field);

List<JsonMap> _maps(JsonMap json, String field) {
  final value = json[field];
  if (value is! List) throw FormatException('Expected array $field');
  return value
      .map((item) => _asMap(item, field))
      .toList(growable: false);
}

List<String> _strings(
  JsonMap json,
  String field,
  Set<String> allowed,
) {
  final value = json[field];
  if (value is! List || value.isEmpty || value.any((item) => item is! String)) {
    throw FormatException('Expected non-empty string array $field');
  }
  final strings = value.cast<String>();
  if (strings.any((value) => !allowed.contains(value)) ||
      strings.toSet().length != strings.length) {
    throw FormatException('Invalid $field');
  }
  return strings.toList(growable: false);
}

DateTime? _optionalTime(JsonMap json, String field) {
  final value = json[field];
  if (value == null) return null;
  if (value is! int) throw FormatException('Expected timestamp $field');
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}
