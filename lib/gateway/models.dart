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

class GatewayProviderRoute {
  const GatewayProviderRoute({
    required this.deviceId,
    required this.providerPluginId,
    required this.providerInstanceId,
  });

  factory GatewayProviderRoute.fromJson(JsonMap json) {
    const fields = {
      'deviceId',
      'providerPluginId',
      'providerInstanceId',
    };
    if (json.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(json.keys.toSet()).isNotEmpty) {
      throw const FormatException(
        'Provider route fields do not match Gateway v1',
      );
    }
    return GatewayProviderRoute(
      deviceId: _requiredString(json, 'deviceId'),
      providerPluginId: _requiredString(json, 'providerPluginId'),
      providerInstanceId: _requiredString(json, 'providerInstanceId'),
    );
  }

  final String deviceId;
  final String providerPluginId;
  final String providerInstanceId;

  String get key =>
      '$deviceId\u0000$providerPluginId\u0000$providerInstanceId';

  JsonMap toJson() => {
        'deviceId': deviceId,
        'providerPluginId': providerPluginId,
        'providerInstanceId': providerInstanceId,
      };

  @override
  bool operator ==(Object other) =>
      other is GatewayProviderRoute &&
      other.deviceId == deviceId &&
      other.providerPluginId == providerPluginId &&
      other.providerInstanceId == providerInstanceId;

  @override
  int get hashCode => Object.hash(
        deviceId,
        providerPluginId,
        providerInstanceId,
      );
}

class HarnessDescriptor {
  const HarnessDescriptor({
    required this.id,
    required this.displayName,
    this.version,
  });

  factory HarnessDescriptor.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'id', 'displayName'},
      optional: const {'version'},
      name: 'Harness descriptor',
    );
    return HarnessDescriptor(
      id: _requiredString(json, 'id'),
      displayName: _requiredString(json, 'displayName'),
      version: _optionalString(json, 'version'),
    );
  }

  final String id;
  final String displayName;
  final String? version;
}

class ProviderChoice {
  const ProviderChoice({
    required this.id,
    required this.displayName,
    this.description,
    this.enabled = true,
    this.disabledReason,
  });

  factory ProviderChoice.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'id', 'displayName'},
      optional: const {'description', 'enabled', 'disabledReason'},
      name: 'Provider choice',
    );
    final enabled = json['enabled'];
    if (enabled != null && enabled is! bool) {
      throw const FormatException('Provider choice enabled must be a boolean');
    }
    return ProviderChoice(
      id: _requiredString(json, 'id'),
      displayName: _requiredString(json, 'displayName'),
      description: _optionalString(json, 'description'),
      enabled: enabled as bool? ?? true,
      disabledReason: _optionalString(json, 'disabledReason'),
    );
  }

  final String id;
  final String displayName;
  final String? description;
  final bool enabled;
  final String? disabledReason;
}

class ProviderChoiceSet {
  const ProviderChoiceSet({required this.options, this.defaultId});

  factory ProviderChoiceSet.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'options'},
      optional: const {'defaultId'},
      name: 'Provider choice set',
    );
    final options = _mapList(json, 'options')
        .map(ProviderChoice.fromJson)
        .toList(growable: false);
    if (options.isEmpty) {
      throw const FormatException('Provider choice set must not be empty');
    }
    _requireUniqueIds(options.map((option) => option.id), 'choice option');
    final defaultId = _optionalString(json, 'defaultId');
    if (defaultId != null &&
        !options.any((option) => option.id == defaultId && option.enabled)) {
      throw const FormatException(
        'Provider choice defaultId must reference an enabled option',
      );
    }
    return ProviderChoiceSet(options: options, defaultId: defaultId);
  }

  final List<ProviderChoice> options;
  final String? defaultId;

  List<ProviderChoice> get availableOptions =>
      options.where((option) => option.enabled).toList(growable: false);

  ProviderChoice? option(String? id) {
    if (id == null) return null;
    for (final option in options) {
      if (option.id == id) return option;
    }
    return null;
  }

  bool accepts(String? id) => option(id)?.enabled == true;
}

sealed class ModelSelection {
  const ModelSelection();

  factory ModelSelection.fromJson(JsonMap json) {
    final kind = _requiredString(json, 'kind');
    return switch (kind) {
      'flat' => FlatModelSelection.fromJson(json),
      'grouped' => GroupedModelSelection.fromJson(json),
      _ => throw FormatException('Unknown model selection kind: $kind'),
    };
  }

  JsonMap toJson();
}

class FlatModelSelection extends ModelSelection {
  const FlatModelSelection({required this.modelId});

  factory FlatModelSelection.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'kind', 'modelId'},
      name: 'Flat model selection',
    );
    if (_requiredString(json, 'kind') != 'flat') {
      throw const FormatException('Flat model selection kind must be flat');
    }
    return FlatModelSelection(modelId: _requiredString(json, 'modelId'));
  }

  final String modelId;

  @override
  JsonMap toJson() => {'kind': 'flat', 'modelId': modelId};

  @override
  bool operator ==(Object other) =>
      other is FlatModelSelection && other.modelId == modelId;

  @override
  int get hashCode => Object.hash('flat', modelId);
}

class GroupedModelSelection extends ModelSelection {
  const GroupedModelSelection({
    required this.providerId,
    required this.modelId,
  });

  factory GroupedModelSelection.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'kind', 'providerId', 'modelId'},
      name: 'Grouped model selection',
    );
    if (_requiredString(json, 'kind') != 'grouped') {
      throw const FormatException(
        'Grouped model selection kind must be grouped',
      );
    }
    return GroupedModelSelection(
      providerId: _requiredString(json, 'providerId'),
      modelId: _requiredString(json, 'modelId'),
    );
  }

  final String providerId;
  final String modelId;

  @override
  JsonMap toJson() => {
        'kind': 'grouped',
        'providerId': providerId,
        'modelId': modelId,
      };

  @override
  bool operator ==(Object other) =>
      other is GroupedModelSelection &&
      other.providerId == providerId &&
      other.modelId == modelId;

  @override
  int get hashCode => Object.hash('grouped', providerId, modelId);
}

class ModelProviderGroup {
  const ModelProviderGroup({
    required this.id,
    required this.displayName,
    required this.models,
    this.description,
  });

  factory ModelProviderGroup.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'id', 'displayName', 'models'},
      optional: const {'description'},
      name: 'Model provider group',
    );
    final models = _mapList(json, 'models')
        .map(ProviderChoice.fromJson)
        .toList(growable: false);
    if (models.isEmpty) {
      throw const FormatException('Model provider group must not be empty');
    }
    _requireUniqueIds(models.map((model) => model.id), 'model');
    return ModelProviderGroup(
      id: _requiredString(json, 'id'),
      displayName: _requiredString(json, 'displayName'),
      description: _optionalString(json, 'description'),
      models: models,
    );
  }

  final String id;
  final String displayName;
  final String? description;
  final List<ProviderChoice> models;
}

sealed class ModelCatalog {
  const ModelCatalog({required this.defaultSelection});

  factory ModelCatalog.fromJson(JsonMap json) {
    final kind = _requiredString(json, 'kind');
    return switch (kind) {
      'flat' => FlatModelCatalog.fromJson(json),
      'grouped' => GroupedModelCatalog.fromJson(json),
      _ => throw FormatException('Unknown model catalog kind: $kind'),
    };
  }

  final ModelSelection? defaultSelection;
  Iterable<ModelSelection> get availableSelections;
  bool accepts(ModelSelection? selection);
  ProviderChoice? modelFor(ModelSelection? selection);
}

class FlatModelCatalog extends ModelCatalog {
  const FlatModelCatalog({
    required this.models,
    FlatModelSelection? defaultSelection,
  }) : super(defaultSelection: defaultSelection);

  factory FlatModelCatalog.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'kind', 'models'},
      optional: const {'defaultSelection'},
      name: 'Flat model catalog',
    );
    final models = _mapList(json, 'models')
        .map(ProviderChoice.fromJson)
        .toList(growable: false);
    if (models.isEmpty) {
      throw const FormatException('Flat model catalog must not be empty');
    }
    _requireUniqueIds(models.map((model) => model.id), 'model');
    final rawDefault = json['defaultSelection'];
    final defaultSelection = rawDefault == null
        ? null
        : ModelSelection.fromJson(_asMap(rawDefault, 'defaultSelection'));
    if (defaultSelection != null && defaultSelection is! FlatModelSelection) {
      throw const FormatException('Flat catalog default must be flat');
    }
    final catalog = FlatModelCatalog(
      models: models,
      defaultSelection: defaultSelection as FlatModelSelection?,
    );
    if (defaultSelection != null && !catalog.accepts(defaultSelection)) {
      throw const FormatException(
        'Flat catalog default must reference an enabled model',
      );
    }
    return catalog;
  }

  final List<ProviderChoice> models;

  @override
  Iterable<ModelSelection> get availableSelections => models
      .where((model) => model.enabled)
      .map((model) => FlatModelSelection(modelId: model.id));

  @override
  bool accepts(ModelSelection? selection) =>
      selection is FlatModelSelection &&
      models.any((model) => model.id == selection.modelId && model.enabled);

  @override
  ProviderChoice? modelFor(ModelSelection? selection) {
    if (selection is! FlatModelSelection) return null;
    for (final model in models) {
      if (model.id == selection.modelId) return model;
    }
    return null;
  }
}

class GroupedModelCatalog extends ModelCatalog {
  const GroupedModelCatalog({
    required this.providers,
    GroupedModelSelection? defaultSelection,
  }) : super(defaultSelection: defaultSelection);

  factory GroupedModelCatalog.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'kind', 'providers'},
      optional: const {'defaultSelection'},
      name: 'Grouped model catalog',
    );
    final providers = _mapList(json, 'providers')
        .map(ModelProviderGroup.fromJson)
        .toList(growable: false);
    if (providers.isEmpty) {
      throw const FormatException('Grouped model catalog must not be empty');
    }
    _requireUniqueIds(providers.map((provider) => provider.id), 'model provider');
    final rawDefault = json['defaultSelection'];
    final defaultSelection = rawDefault == null
        ? null
        : ModelSelection.fromJson(_asMap(rawDefault, 'defaultSelection'));
    if (defaultSelection != null && defaultSelection is! GroupedModelSelection) {
      throw const FormatException('Grouped catalog default must be grouped');
    }
    final catalog = GroupedModelCatalog(
      providers: providers,
      defaultSelection: defaultSelection as GroupedModelSelection?,
    );
    if (defaultSelection != null && !catalog.accepts(defaultSelection)) {
      throw const FormatException(
        'Grouped catalog default must reference an enabled model',
      );
    }
    return catalog;
  }

  final List<ModelProviderGroup> providers;

  @override
  Iterable<ModelSelection> get availableSelections sync* {
    for (final provider in providers) {
      for (final model in provider.models.where((model) => model.enabled)) {
        yield GroupedModelSelection(
          providerId: provider.id,
          modelId: model.id,
        );
      }
    }
  }

  @override
  bool accepts(ModelSelection? selection) =>
      selection is GroupedModelSelection &&
      providers.any((provider) =>
          provider.id == selection.providerId &&
          provider.models.any((model) =>
              model.id == selection.modelId && model.enabled));

  @override
  ProviderChoice? modelFor(ModelSelection? selection) {
    if (selection is! GroupedModelSelection) return null;
    for (final provider in providers) {
      if (provider.id != selection.providerId) continue;
      for (final model in provider.models) {
        if (model.id == selection.modelId) return model;
      }
    }
    return null;
  }

  ModelProviderGroup? providerFor(ModelSelection? selection) {
    if (selection is! GroupedModelSelection) return null;
    for (final provider in providers) {
      if (provider.id == selection.providerId) return provider;
    }
    return null;
  }
}

class TurnSendSelection {
  const TurnSendSelection({
    this.accessModeId,
    this.reasoningEffortId,
    this.model,
  });

  factory TurnSendSelection.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      optional: const {'accessModeId', 'reasoningEffortId', 'model'},
      name: 'Turn send selection',
    );
    final model = json['model'];
    return TurnSendSelection(
      accessModeId: _optionalString(json, 'accessModeId'),
      reasoningEffortId: _optionalString(json, 'reasoningEffortId'),
      model: model == null
          ? null
          : ModelSelection.fromJson(_asMap(model, 'model')),
    );
  }

  final String? accessModeId;
  final String? reasoningEffortId;
  final ModelSelection? model;

  JsonMap toJson() => {
        'accessModeId': ?accessModeId,
        'reasoningEffortId': ?reasoningEffortId,
        'model': ?model?.toJson(),
      };
}

class TurnSendCapabilities {
  const TurnSendCapabilities({
    this.accessMode,
    this.reasoningEffort,
    this.modelCatalog,
  });

  factory TurnSendCapabilities.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      optional: const {'accessMode', 'reasoningEffort', 'modelCatalog'},
      name: 'Turn send capabilities',
    );
    return TurnSendCapabilities(
      accessMode: json['accessMode'] == null
          ? null
          : ProviderChoiceSet.fromJson(_requiredMap(json, 'accessMode')),
      reasoningEffort: json['reasoningEffort'] == null
          ? null
          : ProviderChoiceSet.fromJson(
              _requiredMap(json, 'reasoningEffort'),
            ),
      modelCatalog: json['modelCatalog'] == null
          ? null
          : ModelCatalog.fromJson(_requiredMap(json, 'modelCatalog')),
    );
  }

  final ProviderChoiceSet? accessMode;
  final ProviderChoiceSet? reasoningEffort;
  final ModelCatalog? modelCatalog;

  bool accepts(TurnSendSelection selection) =>
      (accessMode == null
          ? selection.accessModeId == null
          : accessMode!.accepts(selection.accessModeId)) &&
      (reasoningEffort == null
          ? selection.reasoningEffortId == null
          : reasoningEffort!.accepts(selection.reasoningEffortId)) &&
      (modelCatalog == null
          ? selection.model == null
          : modelCatalog!.accepts(selection.model));
}

class GatewayCapabilities {
  const GatewayCapabilities({
    required this.revision,
    required this.methods,
    this.turnSend,
  });

  factory GatewayCapabilities.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'revision', 'methods'},
      optional: const {'turnSend'},
      name: 'Gateway capabilities',
    );
    final methods = _stringList(json, 'methods');
    _requireUniqueIds(methods, 'Gateway method');
    return GatewayCapabilities(
      revision: _requiredString(json, 'revision'),
      methods: methods,
      turnSend: json['turnSend'] == null
          ? null
          : TurnSendCapabilities.fromJson(_requiredMap(json, 'turnSend')),
    );
  }

  final String revision;
  final List<String> methods;
  final TurnSendCapabilities? turnSend;
}

class GatewayProvider {
  const GatewayProvider({
    required this.route,
    required this.providerType,
    required this.displayName,
    required this.status,
    HarnessDescriptor? harness,
    GatewayCapabilities? capabilities,
    List<String>? methods,
    this.version,
  })  : assert(capabilities == null || methods == null),
        // ignore: prefer_initializing_formals
        _harness = harness,
        _capabilities = capabilities,
        _legacyMethods = methods;

  factory GatewayProvider.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {
        'route',
        'pluginId',
        'displayName',
        'harness',
        'status',
        'capabilities',
      },
      optional: const {'version'},
      name: 'Gateway provider',
    );
    final capabilities = _requiredMap(json, 'capabilities');
    final route = GatewayProviderRoute.fromJson(
      _requiredMap(json, 'route'),
    );
    final providerType = _requiredString(json, 'pluginId');
    if (route.providerPluginId != providerType) {
      throw const FormatException('Provider plugin route mismatch');
    }
    return GatewayProvider(
      route: route,
      providerType: providerType,
      displayName: _requiredString(json, 'displayName'),
      version: _optionalString(json, 'version'),
      harness: HarnessDescriptor.fromJson(_requiredMap(json, 'harness')),
      status: ProviderStatus.fromWire(json['status']),
      capabilities: GatewayCapabilities.fromJson(capabilities),
    );
  }

  final GatewayProviderRoute route;
  String get id => route.providerInstanceId;
  final String providerType;
  final String displayName;
  final String? version;
  final HarnessDescriptor? _harness;
  HarnessDescriptor get harness => _harness ??
      HarnessDescriptor(id: providerType, displayName: displayName);
  final ProviderStatus status;
  final GatewayCapabilities? _capabilities;
  final List<String>? _legacyMethods;
  GatewayCapabilities get capabilities => _capabilities ??
      GatewayCapabilities(
        revision: 'legacy-constructor',
        methods: _legacyMethods ?? const [],
      );
  List<String> get methods => capabilities.methods;
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

  GatewayHandshake withProviders(List<GatewayProvider> nextProviders) =>
      GatewayHandshake(
        protocolVersion: protocolVersion,
        serverName: serverName,
        serverVersion: serverVersion,
        providers: nextProviders,
        eventCursor: eventCursor,
        deviceId: deviceId,
        identityFingerprint: identityFingerprint,
        deviceDescriptor: deviceDescriptor,
      );
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
    this.clientRequestId,
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
      clientRequestId: _optionalString(json, 'clientRequestId'),
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
  final String? clientRequestId;
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
    this.turnSendSelection,
    this.wireResource,
  });

  factory ConversationSummary.fromJson(JsonMap json) {
    final activeTurn = json['activeTurn'];
    final turnSendSelection = json['turnSendSelection'];
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
      turnSendSelection: turnSendSelection == null
          ? null
          : TurnSendSelection.fromJson(
              _asMap(turnSendSelection, 'turnSendSelection'),
            ),
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
  final TurnSendSelection? turnSendSelection;
  final JsonMap? wireResource;
}

class TurnSendReceipt {
  const TurnSendReceipt({
    required this.clientRequestId,
    required this.turn,
    required this.inputItem,
    required this.effectiveSelection,
  });

  final String clientRequestId;
  final TurnTask turn;
  final GatewayMessage inputItem;
  final TurnSendSelection effectiveSelection;
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

  TurnTask? get activeTurn {
    final byId = <String, TurnTask>{};
    final summaryTurn = summary.activeTurn;
    if (summaryTurn != null) byId[summaryTurn.id] = summaryTurn;
    for (final turn in turns) {
      final current = byId[turn.id];
      byId[turn.id] = current == null ? turn : _newerTurn(current, turn);
    }
    final active = byId.values
        .where((turn) => !turn.status.isTerminal)
        .toList(growable: false)
      ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
    return active.isEmpty ? null : active.first;
  }

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
      return ConversationDetail(
        summary: summary,
        committedMessages: committedMessages,
        liveOutputMessages: liveOutputMessages,
        turns: _upsertTurn(turns, event.turn),
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

  ConversationDetail accept(TurnSendReceipt receipt) {
    final nextMessages = [...committedMessages];
    final messageIndex = nextMessages.indexWhere(
      (message) => message.id == receipt.inputItem.id,
    );
    if (messageIndex == -1) {
      nextMessages.add(receipt.inputItem);
    } else {
      nextMessages[messageIndex] = receipt.inputItem;
    }
    return ConversationDetail(
      summary: summary,
      committedMessages: nextMessages,
      liveOutputMessages: liveOutputMessages,
      turns: _upsertTurn(turns, receipt.turn),
      lastEventCursor: lastEventCursor,
    );
  }
}

List<TurnTask> _upsertTurn(List<TurnTask> turns, TurnTask incoming) {
  final next = [...turns];
  final index = next.indexWhere((turn) => turn.id == incoming.id);
  if (index == -1) {
    next.add(incoming);
  } else {
    next[index] = _newerTurn(next[index], incoming);
  }
  return next;
}

TurnTask _newerTurn(TurnTask current, TurnTask incoming) {
  final comparison = incoming.updatedAt.compareTo(current.updatedAt);
  if (comparison > 0) return incoming;
  if (comparison < 0) return current;
  return _turnStatusRank(incoming.status) >= _turnStatusRank(current.status)
      ? incoming
      : current;
}

int _turnStatusRank(TurnStatus status) => switch (status) {
      TurnStatus.queued => 0,
      TurnStatus.running => 1,
      TurnStatus.waitingApproval => 2,
      TurnStatus.completed || TurnStatus.failed || TurnStatus.interrupted => 3,
    };

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
      'provider.statusChanged' => GatewayProviderChangedEvent(
          eventCursor: eventCursor,
          provider: GatewayProvider.fromJson(
            _requiredMap(payload, 'provider'),
          ),
        ),
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

class GatewayProviderChangedEvent extends GatewayEvent {
  const GatewayProviderChangedEvent({
    required super.eventCursor,
    required this.provider,
  });

  final GatewayProvider provider;
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

void _validateJsonFields(
  JsonMap json, {
  Set<String> required = const {},
  Set<String> optional = const {},
  required String name,
}) {
  final actual = json.keys.toSet();
  if (required.difference(actual).isNotEmpty ||
      actual.difference({...required, ...optional}).isNotEmpty) {
    throw FormatException('$name fields do not match Gateway v1');
  }
}

void _requireUniqueIds(Iterable<String> values, String name) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) {
      throw FormatException('Duplicate $name id: $value');
    }
  }
}
