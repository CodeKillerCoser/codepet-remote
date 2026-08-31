import 'dart:async';

import 'package:flutter/foundation.dart';

import '../gateway/gateway_client.dart';
import '../gateway/models.dart';
import 'device_models.dart';

enum DeviceConnectionState { offline, connecting, online, failed }

class DeviceSession extends ChangeNotifier {
  DeviceSession({required this.device, required this.clientFactory});

  PairedDevice device;
  final GatewayClient Function() clientFactory;
  GatewayClient? _client;
  GatewayEventWindow? _eventWindow;
  DeviceConnectionState connectionState = DeviceConnectionState.offline;
  GatewayHandshake? handshake;
  String? error;
  List<ConversationSummary> conversations = const [];

  GatewayClient get client => _client!;

  Future<void> connect() async {
    if (connectionState == DeviceConnectionState.connecting) return;
    final oldWindow = _eventWindow;
    final oldClient = _client;
    _eventWindow = null;
    _client = null;
    try {
      await oldWindow?.close();
    } catch (_) {}
    try {
      await oldClient?.close();
    } catch (_) {}
    handshake = null;
    conversations = const [];
    connectionState = DeviceConnectionState.connecting;
    error = null;
    notifyListeners();
    try {
      final client = _client ??= clientFactory();
      final window = client.openEventWindow();
      _eventWindow = window;
      handshake = await client.connect();
      final hostDescriptor = handshake!.deviceDescriptor;
      if (hostDescriptor != null) {
        device = device.withDescriptor(hostDescriptor);
      }
      final page = await client.listConversations();
      conversations = sortRecentConversations(
        deduplicateRoutedConversations(page.conversations),
      );
      window.install(
        baselineCursor: handshake!.eventCursor,
        snapshotCursor: page.snapshotCursor,
        onEvent: _applyEvent,
        onError: (Object value, StackTrace _) {
          unawaited(_failRuntime('事件流异常：$value'));
        },
      );
      connectionState = DeviceConnectionState.online;
    } catch (value) {
      final connectionError = value.toString();
      final window = _eventWindow;
      final client = _client;
      _eventWindow = null;
      _client = null;
      try {
        await window?.close();
      } catch (_) {}
      try {
        await client?.close();
      } catch (_) {}
      handshake = null;
      error = connectionError;
      connectionState = DeviceConnectionState.failed;
      conversations = const [];
    }
    notifyListeners();
  }

  Future<void> _failRuntime(String message) async {
    final window = _eventWindow;
    final client = _client;
    _eventWindow = null;
    _client = null;
    handshake = null;
    conversations = const [];
    error = message;
    connectionState = DeviceConnectionState.failed;
    notifyListeners();
    try {
      await window?.close();
    } catch (_) {}
    try {
      await client?.close();
    } catch (_) {}
  }

  void _applyEvent(GatewayEvent event) {
    if (event is! ConversationUpsertedEvent) return;
    final next = [...conversations];
    final eventKey = conversationRoutingKey(event.conversation);
    final index = next.indexWhere(
      (item) => conversationRoutingKey(item) == eventKey,
    );
    if (index == -1) {
      next.add(event.conversation);
    } else {
      next[index] = event.conversation;
    }
    conversations = sortRecentConversations(next);
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _eventWindow?.close();
    _eventWindow = null;
    await _client?.close();
    _client = null;
    handshake = null;
    error = null;
    conversations = const [];
    connectionState = DeviceConnectionState.offline;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_eventWindow?.close());
    final client = _client;
    if (client != null) unawaited(client.close());
    super.dispose();
  }
}

List<ConversationSummary> sortRecentConversations(
  Iterable<ConversationSummary> values,
) {
  return values.toList(growable: false)
    ..sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
}

Map<String, List<ConversationSummary>> groupConversationsByWorkspace(
  Iterable<ConversationSummary> values,
) {
  final groups = <String, List<ConversationSummary>>{};
  for (final conversation in values) {
    final root = conversation.workspaceRoot;
    if (root == null || root.trim().isEmpty) continue;
    groups.putIfAbsent(root, () => []).add(conversation);
  }
  for (final conversations in groups.values) {
    conversations.sort((left, right) => right.updatedAt.compareTo(left.updatedAt));
  }
  return Map.fromEntries(
    groups.entries.toList()
      ..sort((left, right) {
        final updated = right.value.first.updatedAt.compareTo(left.value.first.updatedAt);
        return updated != 0 ? updated : left.key.compareTo(right.key);
      }),
  );
}

class ConversationProject {
  const ConversationProject({
    required this.hostDeviceId,
    required this.workspaceRoot,
    required this.conversations,
  });

  final String hostDeviceId;
  final String workspaceRoot;
  final List<ConversationSummary> conversations;

  String get key => '$hostDeviceId\u0000$workspaceRoot';
}

List<ConversationProject> groupConversationsByProject({
  required String hostDeviceId,
  required Iterable<ConversationSummary> values,
}) {
  final groups = groupConversationsByWorkspace(
    deduplicateRoutedConversations(values),
  );
  return groups.entries
      .map((entry) => ConversationProject(
            hostDeviceId: hostDeviceId,
            workspaceRoot: entry.key,
            conversations: entry.value,
          ))
      .toList(growable: false);
}

Iterable<ConversationSummary> deduplicateRoutedConversations(
  Iterable<ConversationSummary> values,
) {
  final conversations = <String, ConversationSummary>{};
  for (final conversation in values) {
    final key = conversationRoutingKey(conversation);
    final current = conversations[key];
    if (current == null || conversation.updatedAt.isAfter(current.updatedAt)) {
      conversations[key] = conversation;
    }
  }
  return conversations.values;
}

String conversationRoutingKey(ConversationSummary conversation) =>
    conversation.wireResource == null
        ? '${conversation.providerId}\u0000${conversation.id}'
        : conversation.id;

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
