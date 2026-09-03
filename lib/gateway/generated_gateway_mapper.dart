import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../core/domain/models.dart';

/// Maps generated Gateway SDK values into protocol-neutral application models.
///
/// JSON-RPC envelopes and wire DTO validation stay entirely inside the
/// generated SDK. This adapter contains only domain mapping and route checks.
final class GeneratedGatewayMapper {
  const GeneratedGatewayMapper();

  GatewayProvider provider(sdk.ProviderInstance value) {
    final route = providerRoute(value.route);
    if (route.providerPluginId != value.pluginId) {
      throw const FormatException('Provider plugin route mismatch');
    }
    return GatewayProvider(
      route: route,
      providerType: value.pluginId,
      displayName: value.displayName,
      version: value.version,
      icon: value.icon,
      harness: HarnessDescriptor.fromJson(
        Map<String, dynamic>.from(value.harness.toJson()),
      ),
      status: ProviderStatus.fromWire(value.status.wireValue),
      capabilities: GatewayCapabilities.fromJson(
        Map<String, dynamic>.from(value.capabilities.toJson()),
      ),
    );
  }

  GatewayProviderRoute providerRoute(sdk.GatewayProviderRoute value) =>
      GatewayProviderRoute(
        deviceId: value.deviceId,
        providerPluginId: value.providerPluginId,
        providerInstanceId: value.providerInstanceId,
      );

  ConversationSummary conversation(sdk.Conversation value) {
    final resource = value.resource;
    final project = value.project;
    if (project != null) _requireSameRoute(resource, project);
    final createdAt = _time(value.createdAt) ?? _epoch;
    return ConversationSummary(
      id: resourceKey(resource),
      providerId: resource.providerInstanceId,
      title: value.title,
      preview: value.preview,
      status: ConversationStatus.fromWire(value.status.wireValue),
      permissionLevel: value.permissionLevel ?? PermissionLevel.readOnly,
      model: value.model,
      reasoningEffort: value.reasoningEffort,
      workspaceRoot: value.workspaceRoot,
      project: project == null ? null : resourceId(project),
      createdAt: createdAt,
      updatedAt: _time(value.updatedAt) ?? createdAt,
      activeTurn: value.activeTurn == null ? null : turn(value.activeTurn!),
      turnSendSelection: value.selection == null
          ? null
          : TurnSendSelection.fromJson(
              Map<String, dynamic>.from(value.selection!.toJson()),
            ),
      resource: resourceId(resource),
      readState: value.readState == null
          ? const ConversationReadState(
              unread: false,
              activityVersion: 'activity-0',
            )
          : ConversationReadState(
              unread: value.readState!.unread,
              activityVersion: value.readState!.activityVersion,
            ),
    );
  }

  GatewayProject project(sdk.Project value) => GatewayProject(
        resource: resourceId(value.resource),
        name: value.name,
        roots: value.roots
            .map((root) => ProjectRoot(path: root.path))
            .toList(growable: false),
        metadata: Map.unmodifiable(value.metadata),
        position: value.position,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          value.createdAt,
          isUtc: true,
        ),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(
          value.updatedAt,
          isUtc: true,
        ),
      );

  sdk.ConversationProjectFilter conversationProjectFilter(
    ConversationProjectFilter value,
  ) => switch (value) {
        AllConversationFilter() => sdk.ConversationProjectFilterAll(
            kind: sdk.ConversationProjectFilterAllKind.all,
          ),
        StandaloneConversationFilter() =>
          sdk.ConversationProjectFilterStandalone(
            kind: sdk.ConversationProjectFilterStandaloneKind.standalone,
          ),
        ProjectConversationFilter(:final project) =>
          sdk.ConversationProjectFilterProject(
            kind: sdk.ConversationProjectFilterProjectKind.project,
            project: sdkResourceId(project),
          ),
      };

  List<sdk.ProjectRoot> projectRoots(Iterable<ProjectRoot> roots) => roots
      .map((root) => sdk.ProjectRoot(path: root.path))
      .toList(growable: false);

  TurnTask turn(sdk.TurnTask value) {
    final startedAt = _time(value.startedAt);
    return TurnTask(
      id: resourceKey(value.resource),
      providerId: value.resource.providerInstanceId,
      conversationId: resourceKey(value.conversation),
      status: TurnStatus.fromWire(value.status.wireValue),
      displaySummary: value.displaySummary,
      startedAt: startedAt,
      updatedAt: _time(value.updatedAt) ?? startedAt ?? _epoch,
      completedAt: _time(value.completedAt),
      resource: resourceId(value.resource),
      conversationResource: resourceId(value.conversation),
    );
  }

  GatewayMessage message(sdk.ConversationItem value, int index) {
    final contents = value.contents
        .map(
          (content) => GatewayMessageContent(
            id: content.contentId,
            kind: content.kind.wireValue,
            text: content.text,
          ),
        )
        .toList(growable: false);
    final text = value.contents
        .map((content) => content.text)
        .where((content) => content.isNotEmpty)
        .join('\n');
    final fallback = value.approval?.description ??
        value.title ??
        value.status.wireValue;
    return GatewayMessage(
      id: resourceKey(value.resource),
      itemId: value.resource.nativeResourceId,
      turnId: resourceKey(value.turn),
      role: switch (value.role?.wireValue) {
        'user' => MessageRole.user,
        'assistant' => MessageRole.assistant,
        _ => MessageRole.system,
      },
      kind: value.kind.wireValue,
      content: text.isEmpty ? fallback : text,
      createdAt: _epoch,
      isStreaming: false,
      contentIds: value.contents
          .map((content) => content.contentId)
          .toList(growable: false),
      contents: contents,
      title: value.title ?? value.approval?.title,
      status: value.status.wireValue,
      approvalStatus: value.approval?.status.wireValue,
      approvalDescription: value.approval?.description,
      relatedItemId: value.relatedItem == null
          ? null
          : resourceKey(value.relatedItem!),
      sequence: index,
      tool: value.tool == null ? null : tool(value.tool!),
    );
  }

  GatewayToolInvocation tool(sdk.ToolInvocation value) =>
      GatewayToolInvocation(
        callId: value.callId,
        name: value.name,
        namespace: value.namespace,
        category: value.category.wireValue,
        originKind: value.origin.kind.wireValue,
        originName: value.origin.name,
        input: Map<String, dynamic>.from(value.input),
        rawInput: value.rawInput,
        resultContent: value.result?.content
                .map((content) => GatewayToolContent(
                      id: content.contentId,
                      kind: content.kind.wireValue,
                      text: content.text,
                      uri: content.uri,
                      mimeType: content.mimeType,
                      name: content.name,
                      truncated: content.truncated ?? false,
                      totalBytes: content.totalBytes,
                    ))
                .toList(growable: false) ??
            const [],
        structuredContent: value.result?.structuredContent == null
            ? null
            : Map<String, dynamic>.from(value.result!.structuredContent!),
        errorCode: value.result?.error?.code,
        errorMessage: value.result?.error?.message,
        errorRetryable: value.result?.error?.retryable,
        errorDetails: value.result?.error?.details == null
            ? null
            : Map<String, dynamic>.from(value.result!.error!.details!),
        startedAt: _time(value.timing?.startedAt),
        completedAt: _time(value.timing?.completedAt),
        durationMs: value.timing?.durationMs,
        command: value.command?.command,
        cwd: value.command?.cwd,
        exitCode: value.command?.exitCode,
        processId: value.command?.processId,
        commandActions: value.command?.actions
                ?.map((action) => GatewayToolCommandAction(
                      kind: action.kind.wireValue,
                      command: action.command,
                      name: action.name,
                      path: action.path,
                      query: action.query,
                    ))
                .toList(growable: false) ??
            const [],
        readOnly: value.annotations?.readOnly,
        destructive: value.annotations?.destructive,
        idempotent: value.annotations?.idempotent,
        openWorld: value.annotations?.openWorld,
      );

  TurnSendSelection selection(sdk.TurnSelection value) =>
      TurnSendSelection.fromJson(
        Map<String, dynamic>.from(value.toJson()),
      );

  GatewayEvent event(
    sdk.ProtocolEventEnvelope envelope, {
    required String expectedDeviceId,
    required Set<String> expectedProviderRouteKeys,
  }) {
    final cursor = envelope.eventCursor;
    switch (envelope.event) {
      case sdk.ProtocolEventName.projectChanged:
        final payload = envelope.payload as sdk.ProjectChangedEvent;
        _requireResourceRoute(
          payload.project,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return ProjectChangedEvent(
          eventCursor: cursor,
          project: resourceId(payload.project),
          changeType: switch (payload.changeType) {
            sdk.ProjectChangeType.created => ProjectChangeType.created,
            sdk.ProjectChangeType.updated => ProjectChangeType.updated,
            sdk.ProjectChangeType.deleted => ProjectChangeType.deleted,
          },
        );
      case sdk.ProtocolEventName.providerStatusChanged:
        final payload = envelope.payload as sdk.ProviderStatusChangedEvent;
        final mapped = provider(payload.provider);
        _requireProviderRoute(
          mapped.route,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return GatewayProviderChangedEvent(
          eventCursor: cursor,
          provider: mapped,
        );
      case sdk.ProtocolEventName.conversationUpserted:
        final payload = envelope.payload as sdk.ConversationUpsertedEvent;
        _requireResourceRoute(
          payload.conversation.resource,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return ConversationUpsertedEvent(
          eventCursor: cursor,
          conversation: conversation(payload.conversation),
        );
      case sdk.ProtocolEventName.conversationItemUpserted:
        final payload = envelope.payload as sdk.ConversationItemUpsertedEvent;
        _requireSameRoute(payload.item.resource, payload.item.turn);
        _requireSameRoute(payload.item.resource, payload.item.conversation);
        _requireResourceRoute(
          payload.item.resource,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return ConversationItemUpsertedEvent(
          eventCursor: cursor,
          conversationId: resourceKey(payload.item.conversation),
          item: message(payload.item, 0),
        );
      case sdk.ProtocolEventName.conversationActivityChanged:
        final payload = envelope.payload as sdk.ConversationActivityChangedEvent;
        _requireResourceRoute(
          payload.conversation,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return ConversationActivityChangedEvent(
          eventCursor: cursor,
          conversationId: resourceKey(payload.conversation),
          activityVersion: payload.activityVersion,
        );
      case sdk.ProtocolEventName.turnUpserted:
        final payload = envelope.payload as sdk.TurnUpsertedEvent;
        _requireSameRoute(payload.turn.resource, payload.turn.conversation);
        _requireResourceRoute(
          payload.turn.resource,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return TurnUpsertedEvent(
          eventCursor: cursor,
          turn: turn(payload.turn),
        );
      case sdk.ProtocolEventName.turnOutputDelta:
        final payload = envelope.payload as sdk.TurnOutputDeltaEvent;
        _requireSameRoute(payload.turn, payload.conversation);
        _requireResourceRoute(
          payload.turn,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return TurnOutputDeltaEvent(
          eventCursor: cursor,
          providerId: payload.turn.providerInstanceId,
          conversationId: resourceKey(payload.conversation),
          turnId: resourceKey(payload.turn),
          itemId: payload.itemId,
          contentId: payload.contentId,
          kind: payload.kind.wireValue,
          delta: payload.delta,
        );
      case sdk.ProtocolEventName.approvalRequested:
        final payload = envelope.payload as sdk.ApprovalRequestedEvent;
        return _approvalEvent(
          cursor,
          payload.approval,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
      case sdk.ProtocolEventName.approvalResolved:
        final payload = envelope.payload as sdk.ApprovalResolvedEvent;
        return _approvalEvent(
          cursor,
          payload.approval,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
      case sdk.ProtocolEventName.deviceStatusChanged:
        return UnknownGatewayEvent(
          eventCursor: cursor,
          name: envelope.event.wireName,
          payload: _unsupportedEventPayload(envelope),
        );
    }
  }

  ApprovalChangedEvent _approvalEvent(
    String cursor,
    sdk.Approval approval, {
    required String expectedDeviceId,
    required Set<String> expectedProviderRouteKeys,
  }) {
    _requireSameRoute(approval.resource, approval.conversation);
    _requireSameRoute(approval.resource, approval.turn);
    _requireResourceRoute(
      approval.resource,
      expectedDeviceId: expectedDeviceId,
      expectedProviderRouteKeys: expectedProviderRouteKeys,
    );
    final requestedAt = _time(approval.requestedAt) ?? _epoch;
    final message = GatewayMessage(
      id: resourceKey(approval.resource),
      itemId: approval.resource.nativeResourceId,
      turnId: resourceKey(approval.turn),
      role: MessageRole.system,
      kind: 'approval',
      content: approval.description ?? approval.title,
      createdAt: requestedAt,
      isStreaming: false,
      title: approval.title,
      status: approval.status.wireValue,
      approvalStatus: approval.status.wireValue,
      approvalDescription: approval.description,
    );
    return ApprovalChangedEvent(
      eventCursor: cursor,
      conversationId: resourceKey(approval.conversation),
      approval: message,
    );
  }

  sdk.GatewayProviderRoute sdkProviderRoute(GatewayProviderRoute route) =>
      sdk.GatewayProviderRoute(
        deviceId: route.deviceId,
        providerPluginId: route.providerPluginId,
        providerInstanceId: route.providerInstanceId,
      );

  sdk.RoutedResourceId sdkResourceId(RoutedResourceId value) =>
      sdk.RoutedResourceId(
        deviceId: value.route.deviceId,
        providerPluginId: value.route.providerPluginId,
        providerInstanceId: value.route.providerInstanceId,
        nativeResourceId: value.nativeResourceId,
      );

  RoutedResourceId resourceId(sdk.RoutedResourceId value) =>
      RoutedResourceId(
        route: GatewayProviderRoute(
          deviceId: value.deviceId,
          providerPluginId: value.providerPluginId,
          providerInstanceId: value.providerInstanceId,
        ),
        nativeResourceId: value.nativeResourceId,
      );

  String resourceKey(sdk.RoutedResourceId value) =>
      '${value.deviceId}\u0000${value.providerPluginId}\u0000'
      '${value.providerInstanceId}\u0000${value.nativeResourceId}';

  bool hasSameRoute(sdk.RoutedResourceId left, sdk.RoutedResourceId right) =>
      left.deviceId == right.deviceId &&
      left.providerPluginId == right.providerPluginId &&
      left.providerInstanceId == right.providerInstanceId;

  void requireExpectedResource(
    sdk.RoutedResourceId resource, {
    required String expectedDeviceId,
    required Set<String> expectedProviderRouteKeys,
  }) =>
      _requireResourceRoute(
        resource,
        expectedDeviceId: expectedDeviceId,
        expectedProviderRouteKeys: expectedProviderRouteKeys,
      );

  void _requireSameRoute(
    sdk.RoutedResourceId left,
    sdk.RoutedResourceId right,
  ) {
    if (!hasSameRoute(left, right)) {
      throw const FormatException('Gateway resource route mismatch');
    }
  }

  void _requireResourceRoute(
    sdk.RoutedResourceId resource, {
    required String expectedDeviceId,
    required Set<String> expectedProviderRouteKeys,
  }) {
    _requireProviderRoute(
      GatewayProviderRoute(
        deviceId: resource.deviceId,
        providerPluginId: resource.providerPluginId,
        providerInstanceId: resource.providerInstanceId,
      ),
      expectedDeviceId: expectedDeviceId,
      expectedProviderRouteKeys: expectedProviderRouteKeys,
    );
  }

  void _requireProviderRoute(
    GatewayProviderRoute route, {
    required String expectedDeviceId,
    required Set<String> expectedProviderRouteKeys,
  }) {
    if (route.deviceId != expectedDeviceId ||
        !expectedProviderRouteKeys.contains(route.key)) {
      throw const FormatException(
        'Resource route was not advertised by the connected Host',
      );
    }
  }

  JsonMap _unsupportedEventPayload(sdk.ProtocolEventEnvelope envelope) {
    final value = switch (envelope.event) {
      sdk.ProtocolEventName.deviceStatusChanged =>
        (envelope.payload as sdk.DeviceStatusChangedEvent).toJson(),
      sdk.ProtocolEventName.approvalRequested =>
        (envelope.payload as sdk.ApprovalRequestedEvent).toJson(),
      sdk.ProtocolEventName.approvalResolved =>
        (envelope.payload as sdk.ApprovalResolvedEvent).toJson(),
      _ => const <String, Object?>{},
    };
    return Map<String, dynamic>.from(value);
  }
}

final DateTime _epoch =
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime? _time(int? milliseconds) => milliseconds == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
