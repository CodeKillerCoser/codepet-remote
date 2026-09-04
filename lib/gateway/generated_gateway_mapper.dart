import 'package:codepet_gateway_sdk/codepet_gateway_sdk.dart' as sdk;

import '../core/domain/models.dart';

typedef _ItemParts = ({
  sdk.RoutedResourceId resource,
  sdk.RoutedResourceId turn,
  sdk.RoutedResourceId conversation,
  String kind,
  sdk.ConversationItemStatus status,
  sdk.ConversationItemRole? role,
  String? title,
  sdk.RoutedResourceId? relatedItem,
  sdk.Approval? approval,
  sdk.ToolInvocation? tool,
  List<sdk.ContentBlock> contents,
});

/// Maps generated Gateway SDK values into protocol-neutral application models.
///
/// JSON-RPC envelopes and wire DTO validation stay entirely inside the
/// generated SDK. This adapter contains only domain mapping and providerId checks.
final class GeneratedGatewayMapper {
  const GeneratedGatewayMapper();

  GatewayProvider provider(
    sdk.ProviderSummary value, {
    sdk.GatewayCapabilities? capabilities,
  }) =>
      GatewayProvider(
        id: value.id,
        displayName: value.identity.displayName,
        icon: value.identity.icon,
        defaultWorkspaceRoot: value.identity.defaultWorkspaceRoot,
        status: ProviderStatus.fromWire(value.runtime.status.wireValue),
        runtimeVersion: value.runtime.version,
        executablePath: value.runtime.executablePath,
        authenticationStatus:
            value.runtime.authentication?.status.wireValue,
        authenticationDisplayText:
            value.runtime.authentication?.displayText,
        usageDisplayText: value.runtime.usage?.displayText,
        usageDetails: value.runtime.usage?.details
                ?.map((detail) => Map<String, dynamic>.from(detail.toJson()))
                .toList(growable: false) ??
            const [],
        capabilities: capabilities == null
            ? GatewayCapabilities(
                revision: value.capabilities.revision,
                methods: const [],
              )
            : GatewayCapabilities.fromJson(
                Map<String, dynamic>.from(capabilities.toJson()),
              ),
        capabilitiesLoaded: capabilities != null,
      );

  ConversationSummary conversation(sdk.Conversation value) {
    final resource = value.resource;
    final project = value.project;
    if (project != null) _requireSameRoute(resource, project);
    final createdAt = _time(value.createdAt) ?? _epoch;
    return ConversationSummary(
      id: resourceKey(resource),
      providerId: resource.providerId,
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
      providerId: value.resource.providerId,
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
    final parts = _itemParts(value);
    final contents = parts.contents.map(_content).toList(growable: false);
    final mappedTool = parts.tool == null ? null : tool(parts.tool!);
    final text = contents
        .map((content) => content.displayText)
        .where((content) => content.isNotEmpty)
        .join('\n');
    final fallback = parts.approval?.description ??
        parts.title ??
        parts.status.wireValue;
    final contentIds = <String>{
      ...contents.map((content) => content.id),
      ...?mappedTool?.outcome?.content.map((content) => content.id),
    }.toList(growable: false);
    return GatewayMessage(
      id: resourceKey(parts.resource),
      itemId: parts.resource.nativeResourceId,
      turnId: resourceKey(parts.turn),
      role: switch (parts.role?.wireValue) {
        'user' => MessageRole.user,
        'assistant' => MessageRole.assistant,
        _ => MessageRole.system,
      },
      kind: parts.kind,
      content: text.isEmpty ? fallback : text,
      createdAt: _epoch,
      isStreaming: false,
      contentIds: contentIds,
      contents: contents,
      title: parts.title ?? parts.approval?.title,
      status: parts.status.wireValue,
      approvalStatus: parts.approval?.status.wireValue,
      approvalDescription: parts.approval?.description,
      resource: resourceId(parts.resource),
      approvalDecisions: parts.approval?.decisions
              .map(_approvalDecision)
              .toList(growable: false) ??
          const [],
      approvalDecision: parts.approval?.decision == null
          ? null
          : _approvalDecision(parts.approval!.decision!),
      relatedItemId: parts.relatedItem == null
          ? null
          : resourceKey(parts.relatedItem!),
      sequence: index,
      tool: mappedTool,
    );
  }

  _ItemParts _itemParts(sdk.ConversationItem value) => switch (value) {
        sdk.MessageConversationItem item => (
            resource: item.resource,
            turn: item.turn,
            conversation: item.conversation,
            kind: item.kind.wireValue,
            status: item.status,
            role: item.role,
            title: null,
            relatedItem: null,
            approval: null,
            tool: null,
            contents: item.contents,
          ),
        sdk.ReasoningConversationItem item => (
            resource: item.resource,
            turn: item.turn,
            conversation: item.conversation,
            kind: item.kind.wireValue,
            status: item.status,
            role: null,
            title: null,
            relatedItem: null,
            approval: null,
            tool: null,
            contents: item.contents,
          ),
        sdk.CommandConversationItem item => (
            resource: item.resource,
            turn: item.turn,
            conversation: item.conversation,
            kind: item.kind.wireValue,
            status: item.status,
            role: null,
            title: item.title,
            relatedItem: null,
            approval: null,
            tool: item.tool,
            contents: const [],
          ),
        sdk.FileChangeConversationItem item => (
            resource: item.resource,
            turn: item.turn,
            conversation: item.conversation,
            kind: item.kind.wireValue,
            status: item.status,
            role: null,
            title: item.title,
            relatedItem: null,
            approval: null,
            tool: null,
            contents: item.contents,
          ),
        sdk.ToolConversationItem item => (
            resource: item.resource,
            turn: item.turn,
            conversation: item.conversation,
            kind: item.kind.wireValue,
            status: item.status,
            role: null,
            title: item.title,
            relatedItem: null,
            approval: null,
            tool: item.tool,
            contents: const [],
          ),
        sdk.ApprovalConversationItem item => (
            resource: item.resource,
            turn: item.turn,
            conversation: item.conversation,
            kind: item.kind.wireValue,
            status: item.status,
            role: null,
            title: item.title,
            relatedItem: item.relatedItem,
            approval: item.approval,
            tool: null,
            contents: const [],
          ),
        sdk.UnknownConversationItem item => (
            resource: item.resource,
            turn: item.turn,
            conversation: item.conversation,
            kind: item.kind.wireValue,
            status: item.status,
            role: null,
            title: item.title,
            relatedItem: null,
            approval: null,
            tool: null,
            contents: const [],
          ),
      };

  sdk.RoutedResourceId itemResource(sdk.ConversationItem value) =>
      _itemParts(value).resource;

  sdk.RoutedResourceId itemTurn(sdk.ConversationItem value) =>
      _itemParts(value).turn;

  sdk.RoutedResourceId itemConversation(sdk.ConversationItem value) =>
      _itemParts(value).conversation;

  sdk.RoutedResourceId? itemRelatedItem(sdk.ConversationItem value) =>
      _itemParts(value).relatedItem;

  sdk.Approval? itemApproval(sdk.ConversationItem value) =>
      _itemParts(value).approval;

  bool isUserMessage(sdk.ConversationItem value) =>
      value is sdk.MessageConversationItem &&
      value.role == sdk.ConversationItemRole.user;

  GatewayMessageContent _content(sdk.ContentBlock value) {
    final truncation = switch (value) {
      sdk.TextContentBlock block => block.truncation,
      sdk.ReasoningSummaryContentBlock block => block.truncation,
      sdk.OutputContentBlock block => block.truncation,
      sdk.ActivitySummaryContentBlock block => block.truncation,
      sdk.StructuredJsonContentBlock block => block.truncation,
      sdk.ImageContentBlock block => block.truncation,
      sdk.AudioContentBlock block => block.truncation,
      sdk.ResourceLinkContentBlock block => block.truncation,
      sdk.EmbeddedResourceContentBlock block => block.truncation,
    };
    return switch (value) {
      sdk.TextContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          text: block.text,
          truncation: _truncation(truncation),
        ),
      sdk.ReasoningSummaryContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          text: block.text,
          truncation: _truncation(truncation),
        ),
      sdk.OutputContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          text: block.text,
          truncation: _truncation(truncation),
        ),
      sdk.ActivitySummaryContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          text: block.text,
          truncation: _truncation(truncation),
        ),
      sdk.StructuredJsonContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          value: Map<String, dynamic>.from(block.value),
          truncation: _truncation(truncation),
        ),
      sdk.ImageContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          uri: block.uri,
          mimeType: block.mimeType,
          name: block.name,
          truncation: _truncation(truncation),
        ),
      sdk.AudioContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          uri: block.uri,
          mimeType: block.mimeType,
          name: block.name,
          truncation: _truncation(truncation),
        ),
      sdk.ResourceLinkContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          uri: block.uri,
          mimeType: block.mimeType,
          name: block.name,
          truncation: _truncation(truncation),
        ),
      sdk.EmbeddedResourceContentBlock block => GatewayMessageContent(
          id: block.contentId,
          kind: block.kind.wireValue,
          text: block.text,
          mimeType: block.mimeType,
          name: block.name,
          truncation: _truncation(truncation),
        ),
    };
  }

  GatewayContentTruncation? _truncation(sdk.ContentTruncation? value) =>
      value == null
          ? null
          : GatewayContentTruncation(
              originalBytes: value.originalBytes,
              retainedBytes: value.retainedBytes,
              strategy: value.strategy.wireValue,
            );

  GatewayToolInvocation tool(sdk.ToolInvocation value) =>
      GatewayToolInvocation(
        callId: value.callId,
        name: value.name,
        namespace: value.namespace,
        category: value.category.wireValue,
        originKind: value.origin.kind.wireValue,
        originName: value.origin.name,
        input: _toolInput(value.input),
        outcome: value.outcome == null ? null : _toolOutcome(value.outcome!),
        startedAt: _time(value.timing?.startedAt),
        completedAt: _time(value.timing?.completedAt),
        durationMs: value.timing?.durationMs,
        readOnly: value.annotations?.readOnly,
        destructive: value.annotations?.destructive,
        idempotent: value.annotations?.idempotent,
        openWorld: value.annotations?.openWorld,
      );

  GatewayToolInput _toolInput(sdk.ToolInput value) => switch (value) {
        sdk.CommandToolInput input => GatewayCommandToolInput(
            command: input.command,
            cwd: input.cwd,
            shell: input.shell,
            actions: input.actions?.map(_toolAction).toList(growable: false) ??
                const [],
          ),
        sdk.StructuredToolInput input => GatewayStructuredToolInput(
            value: Map<String, dynamic>.from(input.value),
            truncation: _truncation(input.truncation),
          ),
        sdk.OpaqueToolInput input => GatewayOpaqueToolInput(
            value: input.value,
            mimeType: input.mimeType,
            truncation: _truncation(input.truncation),
          ),
      };

  GatewayToolOutcome _toolOutcome(sdk.ToolOutcome value) => switch (value) {
        sdk.ToolSuccessOutcome outcome => GatewayToolSuccess(
            content: outcome.content.map(_content).toList(growable: false),
            exitCode: outcome.exitCode,
            processId: outcome.processId,
          ),
        sdk.ToolFailureOutcome outcome => GatewayToolFailure(
            content: outcome.content.map(_content).toList(growable: false),
            error: GatewayToolError(
              code: outcome.error.code,
              message: outcome.error.message,
              retryable: outcome.error.retryable,
            ),
            exitCode: outcome.exitCode,
            processId: outcome.processId,
          ),
      };

  GatewayToolCommandAction _toolAction(sdk.ToolCommandAction action) =>
      GatewayToolCommandAction(
        kind: action.kind.wireValue,
        command: action.command,
        name: action.name,
        path: action.path,
        query: action.query,
      );

  GatewayMessage approval(sdk.Approval value) => GatewayMessage(
        id: resourceKey(value.resource),
        itemId: value.resource.nativeResourceId,
        turnId: resourceKey(value.turn),
        role: MessageRole.system,
        kind: 'approval',
        content: value.description ?? value.title,
        createdAt: _time(value.requestedAt) ?? _epoch,
        isStreaming: false,
        title: value.title,
        status: value.status.wireValue,
        approvalStatus: value.status.wireValue,
        approvalDescription: value.description,
        resource: resourceId(value.resource),
        approvalDecisions:
            value.decisions.map(_approvalDecision).toList(growable: false),
        approvalDecision: value.decision == null
            ? null
            : _approvalDecision(value.decision!),
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
      case sdk.ProtocolEventName.providerChanged:
        final payload = envelope.payload as sdk.ProviderChangedEvent;
        final mapped = provider(payload.provider);
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
        final item = _itemParts(payload.item);
        _requireSameRoute(item.resource, item.turn);
        _requireSameRoute(item.resource, item.conversation);
        _requireResourceRoute(
          item.resource,
          expectedDeviceId: expectedDeviceId,
          expectedProviderRouteKeys: expectedProviderRouteKeys,
        );
        return ConversationItemUpsertedEvent(
          eventCursor: cursor,
          conversationId: resourceKey(item.conversation),
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
          providerId: payload.turn.providerId,
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
    return ApprovalChangedEvent(
      eventCursor: cursor,
      conversationId: resourceKey(approval.conversation),
      approval: this.approval(approval),
    );
  }

  sdk.RoutedResourceId sdkResourceId(RoutedResourceId value) =>
      sdk.RoutedResourceId(
        providerId: value.providerId,
        nativeResourceId: value.nativeResourceId,
      );

  RoutedResourceId resourceId(sdk.RoutedResourceId value) =>
      RoutedResourceId(
        providerId: value.providerId,
        nativeResourceId: value.nativeResourceId,
      );

  ApprovalDecision _approvalDecision(sdk.ApprovalDecision value) =>
      switch (value) {
        sdk.ApprovalDecision.approve => ApprovalDecision.approve,
        sdk.ApprovalDecision.deny => ApprovalDecision.deny,
      };

  String resourceKey(sdk.RoutedResourceId value) =>
      '${value.providerId}\u0000${value.nativeResourceId}';

  bool hasSameRoute(sdk.RoutedResourceId left, sdk.RoutedResourceId right) =>
      left.providerId == right.providerId;

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
      throw const FormatException('Gateway resource providerId mismatch');
    }
  }

  void _requireResourceRoute(
    sdk.RoutedResourceId resource, {
    required String expectedDeviceId,
    required Set<String> expectedProviderRouteKeys,
  }) {
    _requireProviderRoute(
      resource.providerId,
      expectedDeviceId: expectedDeviceId,
      expectedProviderRouteKeys: expectedProviderRouteKeys,
    );
  }

  void _requireProviderRoute(
    String providerId, {
    required String expectedDeviceId,
    required Set<String> expectedProviderRouteKeys,
  }) {
    if (!expectedProviderRouteKeys.contains(providerId)) {
      throw const FormatException(
        'Resource providerId was not advertised by the connected Host',
      );
    }
  }

}

final DateTime _epoch =
    DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

DateTime? _time(int? milliseconds) => milliseconds == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true);
