typedef JsonMap = Map<String, dynamic>;

const gatewayProtocolVersion = 1;

/// Stable, protocol-independent identity for a resource owned by a Provider.
///
/// JSON conversion is intentionally kept at the infrastructure boundary; the
/// rest of the application works with this value object instead of inspecting
/// wire maps.
class RoutedResourceId {
  const RoutedResourceId({
    required this.route,
    required this.nativeResourceId,
  });

  final GatewayProviderRoute route;
  final String nativeResourceId;

  String get key => '${route.key}\u0000$nativeResourceId';

  @override
  bool operator ==(Object other) =>
      other is RoutedResourceId &&
      other.route == route &&
      other.nativeResourceId == nativeResourceId;

  @override
  int get hashCode => Object.hash(route, nativeResourceId);
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
        'Device descriptor fields do not match the Gateway schema',
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

abstract final class PermissionLevel {
  static const String readOnly = 'read-only';
  static const String workspaceWrite = 'workspace-write';
  static const String fullAccess = 'full-access';
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

class GatewayMessageContent {
  const GatewayMessageContent({
    required this.id,
    required this.kind,
    required this.text,
  });

  final String id;
  final String kind;
  final String text;

  GatewayMessageContent copyWith({String? text}) => GatewayMessageContent(
        id: id,
        kind: kind,
        text: text ?? this.text,
      );
}

class GatewayToolContent {
  const GatewayToolContent({
    required this.id,
    required this.kind,
    this.text,
    this.uri,
    this.mimeType,
    this.name,
    this.truncated = false,
    this.totalBytes,
  });

  final String id;
  final String kind;
  final String? text;
  final String? uri;
  final String? mimeType;
  final String? name;
  final bool truncated;
  final int? totalBytes;
}

class GatewayToolCommandAction {
  const GatewayToolCommandAction({
    required this.kind,
    required this.command,
    this.name,
    this.path,
    this.query,
  });

  final String kind;
  final String command;
  final String? name;
  final String? path;
  final String? query;
}

class GatewayToolInvocation {
  const GatewayToolInvocation({
    required this.callId,
    required this.name,
    required this.category,
    required this.originKind,
    required this.input,
    this.namespace,
    this.originName,
    this.rawInput,
    this.resultContent = const [],
    this.structuredContent,
    this.errorCode,
    this.errorMessage,
    this.errorRetryable,
    this.errorDetails,
    this.startedAt,
    this.completedAt,
    this.durationMs,
    this.command,
    this.cwd,
    this.exitCode,
    this.processId,
    this.commandActions = const [],
    this.readOnly,
    this.destructive,
    this.idempotent,
    this.openWorld,
  });

  final String callId;
  final String name;
  final String? namespace;
  final String category;
  final String originKind;
  final String? originName;
  final JsonMap input;
  final String? rawInput;
  final List<GatewayToolContent> resultContent;
  final JsonMap? structuredContent;
  final String? errorCode;
  final String? errorMessage;
  final bool? errorRetryable;
  final JsonMap? errorDetails;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final int? durationMs;
  final String? command;
  final String? cwd;
  final int? exitCode;
  final String? processId;
  final List<GatewayToolCommandAction> commandActions;
  final bool? readOnly;
  final bool? destructive;
  final bool? idempotent;
  final bool? openWorld;
}

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
        'Provider route fields do not match the Gateway schema',
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

class ConversationInteraction {
  const ConversationInteraction({
    required this.selection,
    this.leaseExpiresAt,
  });

  final TurnSendSelection selection;
  final DateTime? leaseExpiresAt;
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

class ConversationCreateCapabilities {
  const ConversationCreateCapabilities({
    required this.supportsTitle,
    this.selection,
    this.workspaceMode,
  });

  factory ConversationCreateCapabilities.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'supportsTitle'},
      optional: const {'selection', 'workspaceMode'},
      name: 'Conversation create capabilities',
    );
    final supportsTitle = json['supportsTitle'];
    if (supportsTitle is! bool) {
      throw const FormatException(
        'Conversation create supportsTitle must be a boolean',
      );
    }
    return ConversationCreateCapabilities(
      supportsTitle: supportsTitle,
      selection: json['selection'] == null
          ? null
          : TurnSendCapabilities.fromJson(_requiredMap(json, 'selection')),
      workspaceMode: json['workspaceMode'] == null
          ? null
          : ProviderChoiceSet.fromJson(_requiredMap(json, 'workspaceMode')),
    );
  }

  final bool supportsTitle;
  final TurnSendCapabilities? selection;
  final ProviderChoiceSet? workspaceMode;
}

class GatewayCapabilities {
  const GatewayCapabilities({
    required this.revision,
    required this.methods,
    this.turnSend,
    this.conversationCreate,
  });

  factory GatewayCapabilities.fromJson(JsonMap json) {
    _validateJsonFields(
      json,
      required: const {'revision', 'methods'},
      optional: const {'turnSend', 'conversationCreate'},
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
      conversationCreate: json['conversationCreate'] == null
          ? null
          : ConversationCreateCapabilities.fromJson(
              _requiredMap(json, 'conversationCreate'),
            ),
    );
  }

  final String revision;
  final List<String> methods;
  final TurnSendCapabilities? turnSend;
  final ConversationCreateCapabilities? conversationCreate;
}

class GatewayProvider {
  const GatewayProvider({
    required this.route,
    required this.providerType,
    required this.displayName,
    required this.status,
    required this.harness,
    required this.capabilities,
    this.version,
    this.icon,
  });

  final GatewayProviderRoute route;
  String get id => route.providerInstanceId;
  final String providerType;
  final String displayName;
  final String? version;
  final String? icon;
  final HarnessDescriptor harness;
  final ProviderStatus status;
  final GatewayCapabilities capabilities;
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
    this.resource,
    this.conversationResource,
  });

  final String id;
  final String providerId;
  final String conversationId;
  final TurnStatus status;
  final String? displaySummary;
  final DateTime? startedAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final String? clientRequestId;
  final RoutedResourceId? resource;
  final RoutedResourceId? conversationResource;

  TurnTask withClientRequestId(String value) => TurnTask(
        id: id,
        providerId: providerId,
        conversationId: conversationId,
        status: status,
        updatedAt: updatedAt,
        displaySummary: displaySummary,
        startedAt: startedAt,
        completedAt: completedAt,
        clientRequestId: value,
        resource: resource,
        conversationResource: conversationResource,
      );
}

class ProjectRoot {
  const ProjectRoot({required this.path});

  final String path;
}

class GatewayProject {
  const GatewayProject({
    required this.resource,
    required this.name,
    required this.roots,
    required this.metadata,
    required this.position,
    required this.createdAt,
    required this.updatedAt,
  });

  final RoutedResourceId resource;
  final String name;
  final List<ProjectRoot> roots;
  final Map<String, String> metadata;
  final int position;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get key => resource.key;
}

sealed class ConversationProjectFilter {
  const ConversationProjectFilter();
}

final class AllConversationFilter extends ConversationProjectFilter {
  const AllConversationFilter();
}

final class StandaloneConversationFilter extends ConversationProjectFilter {
  const StandaloneConversationFilter();
}

final class ProjectConversationFilter extends ConversationProjectFilter {
  const ProjectConversationFilter(this.project);

  final RoutedResourceId project;
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
    this.project,
    this.activeTurn,
    this.turnSendSelection,
    this.resource,
    this.readState = const ConversationReadState(
      unread: false,
      activityVersion: 'activity-0',
    ),
  });

  final String id;
  final String providerId;
  final String title;
  final String? preview;
  final ConversationStatus status;
  /// Provider-defined permission mode. Gateway v1 intentionally leaves this
  /// value open so each Provider can expose its native permission policy.
  final String permissionLevel;
  final String? model;
  final String? reasoningEffort;
  final String? workspaceRoot;
  /// Project ownership is independent from [workspaceRoot], which is only the
  /// conversation's current working directory.
  final RoutedResourceId? project;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TurnTask? activeTurn;
  final TurnSendSelection? turnSendSelection;
  final RoutedResourceId? resource;
  final ConversationReadState readState;

  ConversationSummary withReadState(ConversationReadState value) =>
      ConversationSummary(
        id: id,
        providerId: providerId,
        title: title,
        status: status,
        permissionLevel: permissionLevel,
        createdAt: createdAt,
        updatedAt: updatedAt,
        preview: preview,
        model: model,
        reasoningEffort: reasoningEffort,
        workspaceRoot: workspaceRoot,
        project: project,
        activeTurn: activeTurn,
        turnSendSelection: turnSendSelection,
        resource: resource,
        readState: value,
      );

  ConversationSummary withTurn(TurnTask turn) => ConversationSummary(
        id: id,
        providerId: providerId,
        title: title,
        status: switch (turn.status) {
          TurnStatus.queued || TurnStatus.running => ConversationStatus.running,
          TurnStatus.waitingApproval => ConversationStatus.waitingApproval,
          TurnStatus.failed => ConversationStatus.error,
          TurnStatus.completed || TurnStatus.interrupted =>
            ConversationStatus.idle,
        },
        permissionLevel: permissionLevel,
        createdAt: createdAt,
        updatedAt: updatedAt.isAfter(turn.updatedAt) ? updatedAt : turn.updatedAt,
        preview: preview,
        model: model,
        reasoningEffort: reasoningEffort,
        workspaceRoot: workspaceRoot,
        project: project,
        activeTurn: turn.status.isTerminal ? null : turn,
        turnSendSelection: turnSendSelection,
        resource: resource,
        readState: readState,
      );
}

class ConversationReadState {
  const ConversationReadState({
    required this.unread,
    required this.activityVersion,
  });

  final bool unread;
  final String activityVersion;

  ConversationReadState merge(ConversationReadState incoming) {
    final currentVersion = _activityVersionNumber(activityVersion);
    final incomingVersion = _activityVersionNumber(incoming.activityVersion);
    if (currentVersion != null && incomingVersion != null) {
      if (incomingVersion < currentVersion) return this;
      if (incomingVersion > currentVersion) return incoming;
    } else if (incoming.activityVersion != activityVersion) {
      return incoming;
    }
    return ConversationReadState(
      unread: unread && incoming.unread,
      activityVersion: activityVersion,
    );
  }
}

int? _activityVersionNumber(String value) {
  const prefix = 'activity-';
  if (!value.startsWith(prefix)) return null;
  return int.tryParse(value.substring(prefix.length));
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
  final GatewayMessage? inputItem;
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
    this.contents = const [],
    this.title,
    this.status,
    this.approvalStatus,
    this.approvalDescription,
    this.relatedItemId,
    this.sequence,
    this.tool,
    this.clientRequestId,
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
  final List<GatewayMessageContent> contents;
  final String? title;
  final String? status;
  final String? approvalStatus;
  final String? approvalDescription;
  final String? relatedItemId;
  final int? sequence;
  final GatewayToolInvocation? tool;
  final String? clientRequestId;

  GatewayMessage copyWith({
    String? turnId,
    String? content,
    bool? isStreaming,
    List<String>? contentIds,
    List<GatewayMessageContent>? contents,
  }) {
    return GatewayMessage(
      id: id,
      turnId: turnId ?? this.turnId,
      role: role,
      kind: kind,
      content: content ?? this.content,
      createdAt: createdAt,
      isStreaming: isStreaming ?? this.isStreaming,
      isLiveOutput: isLiveOutput,
      itemId: itemId,
      contentId: contentId,
      contentIds: contentIds ?? this.contentIds,
      contents: contents ?? this.contents,
      title: title,
      status: status,
      approvalStatus: approvalStatus,
      approvalDescription: approvalDescription,
      relatedItemId: relatedItemId,
      sequence: sequence,
      tool: tool,
      clientRequestId: clientRequestId,
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

  ConversationDetail withSummary(ConversationSummary value) =>
      ConversationDetail(
        summary: value,
        committedMessages: committedMessages,
        liveOutputMessages: liveOutputMessages,
        turns: turns,
        lastEventCursor: lastEventCursor,
      );

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

  ConversationStatus get effectiveStatus {
    if (summary.status == ConversationStatus.waitingApproval ||
        summary.status == ConversationStatus.waitingUserInput ||
        summary.status == ConversationStatus.error ||
        summary.status == ConversationStatus.archived) {
      return summary.status;
    }
    final turn = activeTurn;
    if (turn == null) return summary.status;
    return switch (turn.status) {
      TurnStatus.queued || TurnStatus.running => ConversationStatus.running,
      TurnStatus.waitingApproval => ConversationStatus.waitingApproval,
      TurnStatus.failed => ConversationStatus.error,
      TurnStatus.completed || TurnStatus.interrupted => ConversationStatus.idle,
    };
  }

  ConversationDetail installCommittedSnapshot(
    ConversationDetail snapshot, {
    String? completedTurnId,
  }) {
    final nextCommittedMessages = [...snapshot.committedMessages];
    for (final pending in committedMessages.where(_isPendingUserMessage)) {
      final hasCanonicalUserItem = nextCommittedMessages.any(
        (message) =>
            message.turnId == pending.turnId &&
            message.role == MessageRole.user &&
            !_isPendingUserMessage(message),
      );
      if (!hasCanonicalUserItem &&
          !nextCommittedMessages.any((message) => message.id == pending.id)) {
        nextCommittedMessages.add(pending);
      }
    }
    var nextSummary = snapshot.summary;
    var nextTurns = snapshot.turns;
    final completedTurn = completedTurnId == null
        ? null
        : _turnById(completedTurnId);
    if (completedTurn != null && completedTurn.status.isTerminal) {
      nextTurns = _upsertTerminalTurn(nextTurns, completedTurn);
      final snapshotActiveTurn = snapshot.summary.activeTurn;
      if (snapshotActiveTurn == null ||
          snapshotActiveTurn.id == completedTurn.id) {
        nextSummary = snapshot.summary.withTurn(completedTurn);
      }
    }
    final committedContentIds = snapshot.committedMessages
        .expand((message) => message.contentIds)
        .toSet();
    return ConversationDetail(
      summary: nextSummary,
      committedMessages: nextCommittedMessages,
      liveOutputMessages: liveOutputMessages
          .where((message) =>
              message.contentId == null ||
              !committedContentIds.contains(message.contentId))
          .where((message) =>
              completedTurnId == null || message.turnId != completedTurnId)
          .toList(growable: false),
      turns: nextTurns,
      lastEventCursor: snapshot.lastEventCursor,
    );
  }

  TurnTask? _turnById(String id) {
    TurnTask? result;
    final summaryTurn = summary.activeTurn;
    if (summaryTurn != null && summaryTurn.id == id) result = summaryTurn;
    for (final turn in turns) {
      if (turn.id != id) continue;
      result = result == null ? turn : _newerTurn(result, turn);
    }
    return result;
  }

  String? _clientRequestIdForTurn(String turnId) =>
      _turnById(turnId)?.clientRequestId;

  ConversationDetail apply(GatewayEvent event) {
    if (event is ConversationUpsertedEvent &&
        event.conversation.id == summary.id) {
      return ConversationDetail(
        // Read state belongs to this client. Broadcast Provider metadata must
        // not clear it while the Host sends a separate activity event.
        summary: event.conversation.withReadState(summary.readState),
        committedMessages: committedMessages,
        liveOutputMessages: liveOutputMessages,
        turns: turns,
        lastEventCursor: event.eventCursor,
      );
    }

    if (event is ConversationActivityChangedEvent &&
        event.conversationId == summary.id) {
      return ConversationDetail(
        summary: summary.withReadState(ConversationReadState(
          unread: true,
          activityVersion: event.activityVersion,
        )),
        committedMessages: committedMessages,
        liveOutputMessages: liveOutputMessages,
        turns: turns,
        lastEventCursor: event.eventCursor,
      );
    }

    if (event is ConversationItemUpsertedEvent &&
        event.conversationId == summary.id) {
      final nextMessages = [...committedMessages];
      var index = nextMessages.indexWhere(
        (message) =>
            message.turnId == event.item.turnId &&
            (message.itemId ?? message.id) ==
                (event.item.itemId ?? event.item.id),
      );
      if (index == -1 && event.item.role == MessageRole.user) {
        final clientRequestId =
            _clientRequestIdForTurn(event.item.turnId);
        if (clientRequestId != null) {
          index = nextMessages.indexWhere(
            (message) =>
                message.id == _pendingUserMessageId(clientRequestId) &&
                message.turnId == event.item.turnId,
          );
        }
      }
      if (index == -1) {
        nextMessages.add(event.item);
      } else {
        nextMessages[index] = event.item;
      }
      final nextLiveOutput = liveOutputMessages
          .where((message) =>
              message.turnId != event.item.turnId ||
              (message.itemId ?? message.id) !=
                  (event.item.itemId ?? event.item.id))
          .toList(growable: false);
      return ConversationDetail(
        summary: summary,
        committedMessages: nextMessages,
        liveOutputMessages: nextLiveOutput,
        turns: turns,
        lastEventCursor: event.eventCursor,
      );
    }

    if (event is TurnUpsertedEvent && event.turn.conversationId == summary.id) {
      return ConversationDetail(
        summary: summary.withTurn(event.turn),
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
      final liveKey = '${event.turnId}\u0000${event.itemId}';
      final messageIndex = nextMessages.indexWhere(
        (message) =>
            message.turnId == event.turnId &&
            message.itemId == event.itemId,
      );
      if (messageIndex == -1) {
        nextMessages.add(
          GatewayMessage(
            id: liveKey,
            turnId: event.turnId,
            role: MessageRole.assistant,
            kind: _itemKindForContentKind(event.kind),
            content: event.delta,
            createdAt: DateTime.now().toUtc(),
            isStreaming: true,
            isLiveOutput: true,
            itemId: event.itemId,
            contentId: event.contentId,
            contentIds: [event.contentId],
            contents: [
              GatewayMessageContent(
                id: event.contentId,
                kind: event.kind,
                text: event.delta,
              ),
            ],
          ),
        );
      } else {
        final current = nextMessages[messageIndex];
        final nextContents = current.contents.isEmpty
            ? [
                GatewayMessageContent(
                  id: current.contentId ?? current.id,
                  kind: _contentKindForLegacyMessage(current),
                  text: current.content,
                ),
              ]
            : [...current.contents];
        final contentIndex = nextContents.indexWhere(
          (content) => content.id == event.contentId,
        );
        if (contentIndex == -1) {
          nextContents.add(
            GatewayMessageContent(
              id: event.contentId,
              kind: event.kind,
              text: event.delta,
            ),
          );
        } else {
          final content = nextContents[contentIndex];
          nextContents[contentIndex] = content.copyWith(
            text: '${content.text}${event.delta}',
          );
        }
        nextMessages[messageIndex] = current.copyWith(
          content: nextContents
              .map((content) => content.text)
              .where((text) => text.isNotEmpty)
              .join('\n'),
          isStreaming: true,
          contentIds: nextContents
              .map((content) => content.id)
              .toList(growable: false),
          contents: nextContents,
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

    if (event is ApprovalChangedEvent &&
        event.conversationId == summary.id) {
      final nextMessages = [...committedMessages];
      final index = nextMessages.indexWhere(
        (message) => message.id == event.approval.id,
      );
      if (index == -1) {
        nextMessages.add(event.approval);
      } else {
        nextMessages[index] = event.approval;
      }
      return ConversationDetail(
        summary: summary,
        committedMessages: nextMessages,
        liveOutputMessages: liveOutputMessages,
        turns: turns,
        lastEventCursor: event.eventCursor,
      );
    }

    return this;
  }

  ConversationDetail accept(TurnSendReceipt receipt) {
    final nextMessages = [...committedMessages];
    final pendingId = _pendingUserMessageId(receipt.clientRequestId);
    final inputItem = receipt.inputItem;
    final acceptedTurn = receipt.turn.withClientRequestId(
      receipt.clientRequestId,
    );
    if (inputItem != null) {
      nextMessages.removeWhere((message) => message.id == pendingId);
      final messageIndex = nextMessages.indexWhere(
        (message) =>
            message.turnId == inputItem.turnId &&
            (message.itemId ?? message.id) ==
                (inputItem.itemId ?? inputItem.id),
      );
      if (messageIndex == -1) {
        nextMessages.add(inputItem);
      } else {
        nextMessages[messageIndex] = inputItem;
      }
    } else {
      final pendingIndex = nextMessages.indexWhere(
        (message) => message.id == pendingId,
      );
      if (pendingIndex != -1) {
        final canonicalArrivedFirst = nextMessages.any(
          (message) =>
              message.turnId == acceptedTurn.id &&
              message.role == MessageRole.user &&
              !_isPendingUserMessage(message),
        );
        if (canonicalArrivedFirst) {
          nextMessages.removeAt(pendingIndex);
        } else {
          nextMessages[pendingIndex] = nextMessages[pendingIndex].copyWith(
            turnId: acceptedTurn.id,
          );
        }
      }
    }
    return ConversationDetail(
      summary: summary,
      committedMessages: nextMessages,
      liveOutputMessages: liveOutputMessages,
      turns: _upsertTurn(turns, acceptedTurn),
      lastEventCursor: lastEventCursor,
    );
  }

  ConversationDetail stageUserInput({
    required String clientRequestId,
    required String text,
    required DateTime createdAt,
  }) {
    final id = _pendingUserMessageId(clientRequestId);
    if (committedMessages.any((message) => message.id == id)) return this;
    return ConversationDetail(
      summary: summary,
      committedMessages: [
        ...committedMessages,
        GatewayMessage(
          id: id,
          turnId: 'pending-turn:$clientRequestId',
          role: MessageRole.user,
          kind: 'message',
          content: text,
          createdAt: createdAt,
          isStreaming: false,
          clientRequestId: clientRequestId,
        ),
      ],
      liveOutputMessages: liveOutputMessages,
      turns: turns,
      lastEventCursor: lastEventCursor,
    );
  }

  ConversationDetail rejectStagedUserInput(String clientRequestId) =>
      ConversationDetail(
        summary: summary,
        committedMessages: committedMessages
            .where((message) =>
                message.id != _pendingUserMessageId(clientRequestId))
            .toList(growable: false),
        liveOutputMessages: liveOutputMessages,
        turns: turns,
        lastEventCursor: lastEventCursor,
      );
}

String _pendingUserMessageId(String clientRequestId) =>
    'pending-user:$clientRequestId';

bool _isPendingUserMessage(GatewayMessage message) {
  final clientRequestId = message.clientRequestId;
  return clientRequestId != null &&
      message.role == MessageRole.user &&
      message.id == _pendingUserMessageId(clientRequestId);
}

String _itemKindForContentKind(String kind) => switch (kind) {
      'text' => 'message',
      'reasoning-summary' => 'reasoning',
      'command' || 'output' => 'command',
      'activity-summary' => 'tool',
      _ => 'unknown',
    };

String _contentKindForLegacyMessage(GatewayMessage message) =>
    switch (message.kind) {
      'reasoning' => 'reasoning-summary',
      'command' => 'command',
      'tool' || 'file-change' || 'approval' => 'activity-summary',
      _ => 'text',
    };

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
  late final TurnTask newer;
  if (current.status.isTerminal && !incoming.status.isTerminal) {
    newer = current;
  } else if (!current.status.isTerminal && incoming.status.isTerminal) {
    newer = incoming;
  } else if (comparison > 0) {
    newer = incoming;
  } else if (comparison < 0) {
    newer = current;
  } else if (_turnStatusRank(incoming.status) >=
      _turnStatusRank(current.status)) {
    newer = incoming;
  } else {
    newer = current;
  }
  final clientRequestId = current.clientRequestId ?? incoming.clientRequestId;
  return clientRequestId == null || newer.clientRequestId == clientRequestId
      ? newer
      : newer.withClientRequestId(clientRequestId);
}

List<TurnTask> _upsertTerminalTurn(
  List<TurnTask> turns,
  TurnTask terminal,
) {
  final next = [...turns];
  final index = next.indexWhere((turn) => turn.id == terminal.id);
  if (index == -1) {
    next.add(terminal);
  } else {
    final clientRequestId =
        terminal.clientRequestId ?? next[index].clientRequestId;
    next[index] = clientRequestId == null ||
            terminal.clientRequestId == clientRequestId
        ? terminal
        : terminal.withClientRequestId(clientRequestId);
  }
  return next;
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

  final List<ConversationSummary> conversations;
  final String? nextCursor;
  final String snapshotCursor;
}

class ProjectPage {
  const ProjectPage({
    required this.projects,
    required this.snapshotCursor,
    this.nextCursor,
  });

  final List<GatewayProject> projects;
  final String? nextCursor;
  final String snapshotCursor;
}

sealed class GatewayEvent {
  const GatewayEvent({required this.eventCursor});

  final String eventCursor;
}

class GatewayProviderChangedEvent extends GatewayEvent {
  const GatewayProviderChangedEvent({
    required super.eventCursor,
    required this.provider,
  });

  final GatewayProvider provider;
}

enum ProjectChangeType { created, updated, deleted }

class ProjectChangedEvent extends GatewayEvent {
  const ProjectChangedEvent({
    required super.eventCursor,
    required this.project,
    required this.changeType,
  });

  final RoutedResourceId project;
  final ProjectChangeType changeType;
}

class ConversationUpsertedEvent extends GatewayEvent {
  const ConversationUpsertedEvent({
    required super.eventCursor,
    required this.conversation,
  });

  final ConversationSummary conversation;
}

class ConversationItemUpsertedEvent extends GatewayEvent {
  const ConversationItemUpsertedEvent({
    required super.eventCursor,
    required this.conversationId,
    required this.item,
  });

  final String conversationId;
  final GatewayMessage item;
}

class ConversationActivityChangedEvent extends GatewayEvent {
  const ConversationActivityChangedEvent({
    required super.eventCursor,
    required this.conversationId,
    required this.activityVersion,
  });

  final String conversationId;
  final String activityVersion;
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

class ApprovalChangedEvent extends GatewayEvent {
  const ApprovalChangedEvent({
    required super.eventCursor,
    required this.conversationId,
    required this.approval,
  });

  final String conversationId;
  final GatewayMessage approval;
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

void _validateJsonFields(
  JsonMap json, {
  Set<String> required = const {},
  Set<String> optional = const {},
  required String name,
}) {
  final actual = json.keys.toSet();
  if (required.difference(actual).isNotEmpty ||
      actual.difference({...required, ...optional}).isNotEmpty) {
    throw FormatException('$name fields do not match the Gateway schema');
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
