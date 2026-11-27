part of 'device_session.dart';

/// Tasks waiting for input still require attention and must remain in Recent.
bool conversationIsInProgress(ConversationSummary conversation) =>
    conversation.status == ConversationStatus.running ||
    conversation.status == ConversationStatus.waitingApproval ||
    conversation.status == ConversationStatus.waitingUserInput;

List<ConversationSummary> sortRecentConversations(
  Iterable<ConversationSummary> values,
) {
  return values.toList(growable: false)..sort(_compareRecentConversations);
}

int _compareRecentConversations(
  ConversationSummary left,
  ConversationSummary right,
) {
  final updatedAt = right.updatedAt.compareTo(left.updatedAt);
  if (updatedAt != 0) return updatedAt;
  return conversationRoutingKey(left).compareTo(conversationRoutingKey(right));
}

List<ConversationSummary> mergeRoutedConversations(
  Iterable<ConversationSummary> existing,
  Iterable<ConversationSummary> incoming,
) => sortRecentConversations(
  deduplicateRoutedConversations([...existing, ...incoming]),
);

List<GatewayProject> sortProjects(Iterable<GatewayProject> values) {
  return values.toList(growable: false)..sort((left, right) {
    final position = left.position.compareTo(right.position);
    return position != 0 ? position : left.key.compareTo(right.key);
  });
}

List<GatewayProject> mergeRoutedProjects(
  Iterable<GatewayProject> existing,
  Iterable<GatewayProject> incoming,
) {
  final projects = <String, GatewayProject>{
    for (final project in existing) project.key: project,
  };
  for (final project in incoming) {
    final current = projects[project.key];
    if (current == null || !project.updatedAt.isBefore(current.updatedAt)) {
      projects[project.key] = project;
    }
  }
  return sortProjects(projects.values);
}

List<GatewayProject> replaceProviderProjects(
  Iterable<GatewayProject> existing,
  String providerId,
  Iterable<GatewayProject> replacement,
) => sortProjects([
  for (final project in existing)
    if (project.resource.providerId != providerId) project,
  ...replacement,
]);

Iterable<ConversationSummary> deduplicateRoutedConversations(
  Iterable<ConversationSummary> values,
) {
  final conversations = <String, ConversationSummary>{};
  for (final conversation in values) {
    final key = conversationRoutingKey(conversation);
    final current = conversations[key];
    // Callers pass the older projection first, so equal timestamps must let the
    // later snapshot refresh metadata such as an asynchronously generated title.
    if (current == null ||
        !conversation.updatedAt.isBefore(current.updatedAt)) {
      conversations[key] = conversation;
    }
  }
  return conversations.values;
}

String conversationRoutingKey(ConversationSummary conversation) {
  final resource = conversation.resource;
  if (resource != null) return resource.key;
  return '${conversation.providerId}\u0000${conversation.id}';
}

String _tailRunes(String value, int limit) {
  final runes = value.runes.toList(growable: false);
  if (runes.length <= limit) return value;
  return String.fromCharCodes(runes.skip(runes.length - limit));
}

enum _ConversationListScopeKind { all, standalone, project }

class _ConversationListScope {
  const _ConversationListScope._({
    required this.providerId,
    required this.kind,
    this.project,
  });

  const _ConversationListScope.all(String providerId)
    : this._(providerId: providerId, kind: _ConversationListScopeKind.all);

  const _ConversationListScope.standalone(String providerId)
    : this._(
        providerId: providerId,
        kind: _ConversationListScopeKind.standalone,
      );

  _ConversationListScope.project(RoutedResourceId project)
    : this._(
        providerId: project.providerId,
        kind: _ConversationListScopeKind.project,
        project: project,
      );

  final String providerId;
  final _ConversationListScopeKind kind;
  final RoutedResourceId? project;

  ConversationProjectFilter get filter => switch (kind) {
    _ConversationListScopeKind.all => const AllConversationFilter(),
    _ConversationListScopeKind.standalone =>
      const StandaloneConversationFilter(),
    _ConversationListScopeKind.project => ProjectConversationFilter(project!),
  };

  @override
  bool operator ==(Object other) =>
      other is _ConversationListScope &&
      other.providerId == providerId &&
      other.kind == kind &&
      other.project == project;

  @override
  int get hashCode => Object.hash(providerId, kind, project);
}

Future<int> replaceDeviceSession(
  List<DeviceSession> sessions,
  DeviceSession replacement,
) async {
  final index = sessions.indexWhere(
    (session) => session.device.deviceId == replacement.device.deviceId,
  );
  if (index == -1) {
    sessions.add(replacement);
    return sessions.length - 1;
  }
  final previous = sessions[index];
  sessions[index] = replacement;
  await previous.disconnect();
  previous.dispose();
  return index;
}
