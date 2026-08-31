typedef JsonMap = Map<String, dynamic>;

const gatewayProtocolVersion = 1;

class DeviceConnection {
  const DeviceConnection({
    required this.deviceName,
    required this.gatewayUri,
    required this.pairingToken,
  });

  final String deviceName;
  final Uri gatewayUri;
  final String pairingToken;
}

class DeviceDescriptor {
  const DeviceDescriptor({
    required this.deviceName,
    required this.operatingSystem,
    required this.systemVersion,
  });

  factory DeviceDescriptor.fromJson(JsonMap json) {
    const fields = {'deviceName', 'operatingSystem', 'systemVersion'};
    if (json.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(json.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'Device descriptor fields do not match Gateway v1',
      );
    }
    return DeviceDescriptor(
      deviceName: _requiredString(json, 'deviceName'),
      operatingSystem: _requiredString(json, 'operatingSystem'),
      systemVersion: _requiredString(json, 'systemVersion'),
    );
  }

  final String deviceName;
  final String operatingSystem;
  final String systemVersion;

  JsonMap toJson() => {
        'deviceName': deviceName,
        'operatingSystem': operatingSystem,
        'systemVersion': systemVersion,
      };
}

enum ProviderStatus {
  disconnected('disconnected'),
  connecting('connecting'),
  ready('ready'),
  unavailable('unavailable'),
  error('error');

  const ProviderStatus(this.wireValue);

  final String wireValue;

  static ProviderStatus fromWire(Object? value) {
    return ProviderStatus.values.firstWhere(
      (status) => status.wireValue == value,
      orElse: () => throw FormatException('Unknown provider status: $value'),
    );
  }
}

enum ConversationStatus {
  idle('idle'),
  running('running'),
  waitingApproval('waiting-approval'),
  waitingUserInput('waiting-user-input'),
  error('error'),
  archived('archived');

  const ConversationStatus(this.wireValue);

  final String wireValue;

  static ConversationStatus fromWire(Object? value) {
    return ConversationStatus.values.firstWhere(
      (status) => status.wireValue == value,
      orElse: () => throw FormatException('Unknown conversation status: $value'),
    );
  }
}

enum PermissionLevel {
  readOnly('read-only'),
  workspaceWrite('workspace-write'),
  fullAccess('full-access');

  const PermissionLevel(this.wireValue);

  final String wireValue;

  static PermissionLevel fromWire(Object? value) {
    return PermissionLevel.values.firstWhere(
      (level) => level.wireValue == value,
      orElse: () => throw FormatException('Unknown permission level: $value'),
    );
  }
}

enum TurnStatus {
  queued('queued'),
  running('running'),
  waitingApproval('waiting-approval'),
  completed('completed'),
  failed('failed'),
  interrupted('interrupted');

  const TurnStatus(this.wireValue);

  final String wireValue;

  bool get isTerminal =>
      this == TurnStatus.completed ||
      this == TurnStatus.failed ||
      this == TurnStatus.interrupted;

  static TurnStatus fromWire(Object? value) {
    return TurnStatus.values.firstWhere(
      (status) => status.wireValue == value,
      orElse: () => throw FormatException('Unknown turn status: $value'),
    );
  }
}

enum MessageRole { user, assistant, system }

class GatewayProvider {
  const GatewayProvider({
    required this.id,
    required this.providerType,
    required this.displayName,
    required this.status,
    required this.methods,
  });

  factory GatewayProvider.fromJson(JsonMap json) {
    final capabilities = _requiredMap(json, 'capabilities');
    return GatewayProvider(
      id: _requiredString(json, 'id'),
      providerType: _requiredString(json, 'providerType'),
      displayName: _requiredString(json, 'displayName'),
      status: ProviderStatus.fromWire(json['status']),
      methods: _stringList(capabilities, 'methods'),
    );
  }

  final String id;
  final String providerType;
  final String displayName;
  final ProviderStatus status;
  final List<String> methods;
}

class GatewayHandshake {
  const GatewayHandshake({
    required this.protocolVersion,
    required this.serverName,
    required this.serverVersion,
    required this.providers,
    required this.eventCursor,
    this.deviceId,
    this.identityFingerprint,
    this.deviceDescriptor,
  });

  factory GatewayHandshake.fromJson(JsonMap json) {
    return GatewayHandshake(
      protocolVersion: _requiredInt(json, 'protocolVersion'),
      serverName: _requiredString(json, 'serverName'),
      serverVersion: _requiredString(json, 'serverVersion'),
      providers: _mapList(json, 'providers')
          .map(GatewayProvider.fromJson)
          .toList(growable: false),
      eventCursor: _requiredString(json, 'eventCursor'),
    );
  }

  final int protocolVersion;
  final String serverName;
  final String serverVersion;
  final List<GatewayProvider> providers;
  final String eventCursor;
  final String? deviceId;
  final String? identityFingerprint;
  final DeviceDescriptor? deviceDescriptor;
}

class TurnTask {
  const TurnTask({
    required this.id,
    required this.providerId,
    required this.conversationId,
    required this.status,
    required this.updatedAt,
    this.displaySummary,
    this.startedAt,
    this.completedAt,
    this.wireResource,
    this.conversationWireResource,
  });

  factory TurnTask.fromJson(JsonMap json) {
    return TurnTask(
      id: _requiredString(json, 'id'),
      providerId: _requiredString(json, 'providerId'),
      conversationId: _requiredString(json, 'conversationId'),
      status: TurnStatus.fromWire(json['status']),
      displaySummary: _optionalString(json, 'displaySummary'),
      startedAt: _optionalDateTime(json, 'startedAt'),
      updatedAt: _requiredDateTime(json, 'updatedAt'),
      completedAt: _optionalDateTime(json, 'completedAt'),
    );
  }

  final String id;
  final String providerId;
  final String conversationId;
  final TurnStatus status;
  final String? displaySummary;
  final DateTime? startedAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final JsonMap? wireResource;
  final JsonMap? conversationWireResource;
}

class ConversationSummary {
  const ConversationSummary({
    required this.id,
    required this.providerId,
    required this.title,
    required this.status,
    required this.permissionLevel,
    required this.createdAt,
    required this.updatedAt,
    this.preview,
    this.model,
    this.reasoningEffort,
    this.workspaceRoot,
    this.activeTurn,
    this.wireResource,
  });

  factory ConversationSummary.fromJson(JsonMap json) {
    final activeTurn = json['activeTurn'];
    return ConversationSummary(
      id: _requiredString(json, 'id'),
      providerId: _requiredString(json, 'providerId'),
      title: _requiredString(json, 'title'),
      preview: _optionalString(json, 'preview'),
      status: ConversationStatus.fromWire(json['status']),
      permissionLevel: PermissionLevel.fromWire(json['permissionLevel']),
      model: _optionalString(json, 'model'),
      reasoningEffort: _optionalString(json, 'reasoningEffort'),
      workspaceRoot: _optionalString(json, 'workspaceRoot'),
      createdAt: _requiredDateTime(json, 'createdAt'),
      updatedAt: _requiredDateTime(json, 'updatedAt'),
      activeTurn: activeTurn == null
          ? null
          : TurnTask.fromJson(_asMap(activeTurn, 'activeTurn')),
    );
  }

  final String id;
  final String providerId;
  final String title;
  final String? preview;
  final ConversationStatus status;
  final PermissionLevel permissionLevel;
  final String? model;
  final String? reasoningEffort;
  final String? workspaceRoot;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TurnTask? activeTurn;
  final JsonMap? wireResource;
}

class GatewayMessage {
  const GatewayMessage({
    required this.id,
    required this.turnId,
    required this.role,
    required this.kind,
    required this.content,
    required this.createdAt,
    required this.isStreaming,
    this.isLiveOutput = false,
    this.itemId,
    this.contentId,
    this.contentIds = const [],
    this.title,
    this.status,
    this.approvalStatus,
  });

  final String id;
  final String turnId;
  final MessageRole role;
  final String kind;
  final String content;
  final DateTime createdAt;
  final bool isStreaming;
  final bool isLiveOutput;
  final String? itemId;
  final String? contentId;
  final List<String> contentIds;
  final String? title;
  final String? status;
  final String? approvalStatus;

  GatewayMessage copyWith({
    String? content,
    bool? isStreaming,
  }) {
    return GatewayMessage(
      id: id,
      turnId: turnId,
      role: role,
      kind: kind,
      content: content ?? this.content,
      createdAt: createdAt,
      isStreaming: isStreaming ?? this.isStreaming,
      isLiveOutput: isLiveOutput,
      itemId: itemId,
      contentId: contentId,
      contentIds: contentIds,
      title: title,
      status: status,
      approvalStatus: approvalStatus,
    );
  }
}

class ConversationDetail {
  const ConversationDetail({
    required this.summary,
    this.committedMessages = const [],
    this.liveOutputMessages = const [],
    this.turns = const [],
    this.lastEventCursor,
  });

  final ConversationSummary summary;
  final List<GatewayMessage> committedMessages;
  final List<GatewayMessage> liveOutputMessages;
  List<GatewayMessage> get messages => [
        ...committedMessages,
        ...liveOutputMessages,
      ];
  final List<TurnTask> turns;
  final String? lastEventCursor;

  ConversationDetail installCommittedSnapshot(
    ConversationDetail snapshot, {
    String? completedTurnId,
  }) {
    final committedContentIds = snapshot.committedMessages
        .expand((message) => message.contentIds)
        .toSet();
    return ConversationDetail(
      summary: snapshot.summary,
      committedMessages: snapshot.committedMessages,
      liveOutputMessages: liveOutputMessages
          .where((message) =>
              message.contentId == null ||
              !committedContentIds.contains(message.contentId))
          .where((message) =>
              completedTurnId == null || message.turnId != completedTurnId)
          .toList(growable: false),
      turns: snapshot.turns,
      lastEventCursor: snapshot.lastEventCursor,
    );
  }

  ConversationDetail apply(GatewayEvent event) {
    if (event is ConversationUpsertedEvent &&
        event.conversation.id == summary.id) {
      return ConversationDetail(
        summary: event.conversation,
        committedMessages: committedMessages,
        liveOutputMessages: liveOutputMessages,
        turns: turns,
        lastEventCursor: event.eventCursor,
      );
    }

    if (event is TurnUpsertedEvent && event.turn.conversationId == summary.id) {
      final nextTurns = [...turns];
      final turnIndex = nextTurns.indexWhere((turn) => turn.id == event.turn.id);
      if (turnIndex == -1) {
        nextTurns.add(event.turn);
      } else {
        nextTurns[turnIndex] = event.turn;
      }
      return ConversationDetail(
        summary: summary,
        committedMessages: committedMessages,
        liveOutputMessages: liveOutputMessages,
        turns: nextTurns,
        lastEventCursor: event.eventCursor,
      );
    }

    if (event is TurnOutputDeltaEvent && event.conversationId == summary.id) {
      final alreadyCommitted = committedMessages.any(
        (message) => message.contentIds.contains(event.contentId),
      );
      if (alreadyCommitted) {
        return ConversationDetail(
          summary: summary,
          committedMessages: committedMessages,
          liveOutputMessages: liveOutputMessages,
          turns: turns,
          lastEventCursor: event.eventCursor,
        );
      }
      final nextMessages = [...liveOutputMessages];
      final liveKey =
          '${event.turnId}\u0000${event.itemId}\u0000${event.contentId}';
      final messageIndex = nextMessages.indexWhere(
        (message) => message.id == liveKey,
      );
      if (messageIndex == -1) {
        nextMessages.add(
          GatewayMessage(
            id: liveKey,
            turnId: event.turnId,
            role: MessageRole.assistant,
            kind: event.kind,
            content: event.delta,
            createdAt: DateTime.now().toUtc(),
            isStreaming: true,
            isLiveOutput: true,
            itemId: event.itemId,
            contentId: event.contentId,
            contentIds: [event.contentId],
          ),
        );
      } else {
        final current = nextMessages[messageIndex];
        nextMessages[messageIndex] = current.copyWith(
          content: '${current.content}${event.delta}',
          isStreaming: true,
        );
      }
      return ConversationDetail(
        summary: summary,
        committedMessages: committedMessages,
        liveOutputMessages: nextMessages,
        turns: turns,
        lastEventCursor: event.eventCursor,
      );
    }

    return this;
  }
}

class ConversationPage {
  const ConversationPage({
    required this.conversations,
    required this.snapshotCursor,
    this.nextCursor,
  });

  factory ConversationPage.fromJson(JsonMap json) {
    return ConversationPage(
      conversations: _mapList(json, 'conversations')
          .map(ConversationSummary.fromJson)
          .toList(growable: false),
      nextCursor: _optionalString(json, 'nextCursor'),
      snapshotCursor: _requiredString(json, 'snapshotCursor'),
    );
  }

  final List<ConversationSummary> conversations;
  final String? nextCursor;
  final String snapshotCursor;
}

sealed class GatewayEvent {
  const GatewayEvent({required this.eventCursor});

  factory GatewayEvent.fromJson(JsonMap json) {
    final eventCursor = _requiredString(json, 'eventCursor');
    final eventName = _requiredString(json, 'event');
    final payload = _requiredMap(json, 'payload');
    return switch (eventName) {
      'conversation.upserted' => ConversationUpsertedEvent(
          eventCursor: eventCursor,
          conversation: ConversationSummary.fromJson(
            _requiredMap(payload, 'conversation'),
          ),
        ),
      'turn.upserted' => TurnUpsertedEvent(
          eventCursor: eventCursor,
          turn: TurnTask.fromJson(_requiredMap(payload, 'turn')),
        ),
      'turn.outputDelta' => TurnOutputDeltaEvent(
          eventCursor: eventCursor,
          providerId: _requiredString(payload, 'providerId'),
          conversationId: _requiredString(payload, 'conversationId'),
          turnId: _requiredString(payload, 'turnId'),
          itemId: _requiredString(payload, 'itemId'),
          contentId: _requiredString(payload, 'contentId'),
          kind: _requiredString(payload, 'kind'),
          delta: _requiredString(payload, 'delta', allowEmpty: true),
        ),
      _ => UnknownGatewayEvent(
          eventCursor: eventCursor,
          name: eventName,
          payload: payload,
        ),
    };
  }

  final String eventCursor;
}

class ConversationUpsertedEvent extends GatewayEvent {
  const ConversationUpsertedEvent({
    required super.eventCursor,
    required this.conversation,
  });

  final ConversationSummary conversation;
}

class TurnUpsertedEvent extends GatewayEvent {
  const TurnUpsertedEvent({
    required super.eventCursor,
    required this.turn,
  });

  final TurnTask turn;
}

class TurnOutputDeltaEvent extends GatewayEvent {
  const TurnOutputDeltaEvent({
    required super.eventCursor,
    required this.providerId,
    required this.conversationId,
    required this.turnId,
    required this.itemId,
    required this.contentId,
    required this.kind,
    required this.delta,
  });

  final String providerId;
  final String conversationId;
  final String turnId;
  final String itemId;
  final String contentId;
  final String kind;
  final String delta;
}

class UnknownGatewayEvent extends GatewayEvent {
  const UnknownGatewayEvent({
    required super.eventCursor,
    required this.name,
    required this.payload,
  });

  final String name;
  final JsonMap payload;
}

JsonMap _asMap(Object? value, String field) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  throw FormatException('Expected object for "$field"');
}

JsonMap _requiredMap(JsonMap json, String field) => _asMap(json[field], field);

List<JsonMap> _mapList(JsonMap json, String field) {
  final value = json[field];
  if (value is! List) {
    throw FormatException('Expected array for "$field"');
  }
  return value.map((item) => _asMap(item, field)).toList(growable: false);
}

List<String> _stringList(JsonMap json, String field) {
  final value = json[field];
  if (value is! List || value.any((item) => item is! String)) {
    throw FormatException('Expected string array for "$field"');
  }
  return value.cast<String>().toList(growable: false);
}

String _requiredString(
  JsonMap json,
  String field, {
  bool allowEmpty = false,
}) {
  final value = json[field];
  if (value is! String || (!allowEmpty && value.isEmpty)) {
    throw FormatException('Expected string for "$field"');
  }
  return value;
}

String? _optionalString(JsonMap json, String field) {
  final value = json[field];
  if (value == null) {
    return null;
  }
  if (value is! String) {
    throw FormatException('Expected string for "$field"');
  }
  return value;
}

int _requiredInt(JsonMap json, String field) {
  final value = json[field];
  if (value is! int) {
    throw FormatException('Expected integer for "$field"');
  }
  return value;
}

DateTime _requiredDateTime(JsonMap json, String field) {
  return DateTime.fromMillisecondsSinceEpoch(
    _requiredInt(json, field),
    isUtc: true,
  );
}

DateTime? _optionalDateTime(JsonMap json, String field) {
  final value = json[field];
  if (value == null) {
    return null;
  }
  if (value is! int) {
    throw FormatException('Expected integer for "$field"');
  }
  return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
}
