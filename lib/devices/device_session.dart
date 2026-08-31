import 'dart:async';

import 'package:flutter/foundation.dart';

import '../gateway/gateway_client.dart';
import '../gateway/models.dart';
import 'device_models.dart';

enum DeviceConnectionState { offline, connecting, online, failed }

class DeviceSession extends ChangeNotifier {
  DeviceSession({required this.device, required this.clientFactory});

  final PairedDevice device;
  final GatewayClient Function() clientFactory;
  GatewayClient? _client;
  StreamSubscription<GatewayEvent>? _eventSubscription;
  DeviceConnectionState connectionState = DeviceConnectionState.offline;
  GatewayHandshake? handshake;
  String? error;
  List<ConversationSummary> conversations = const [];

  GatewayClient get client => _client!;

  Future<void> connect() async {
    if (connectionState == DeviceConnectionState.connecting) return;
    connectionState = DeviceConnectionState.connecting;
    error = null;
    notifyListeners();
    try {
      final client = _client ??= clientFactory();
      handshake = await client.connect();
      await _eventSubscription?.cancel();
      _eventSubscription = client.events.listen(
        _applyEvent,
        onError: (Object value) {
          error = '事件流异常：$value';
          connectionState = DeviceConnectionState.failed;
          conversations = const [];
          notifyListeners();
        },
        onDone: () {
          if (connectionState == DeviceConnectionState.online) {
            connectionState = DeviceConnectionState.offline;
            conversations = const [];
            notifyListeners();
          }
        },
      );
      final page = await client.listConversations();
      conversations = sortRecentConversations(page.conversations);
      connectionState = DeviceConnectionState.online;
    } catch (value) {
      final connectionError = value.toString();
      final subscription = _eventSubscription;
      final client = _client;
      _eventSubscription = null;
      _client = null;
      try {
        await subscription?.cancel();
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

  void _applyEvent(GatewayEvent event) {
    if (event is! ConversationUpsertedEvent) return;
    final next = [...conversations];
    final index = next.indexWhere((item) =>
        item.id == event.conversation.id &&
        item.providerId == event.conversation.providerId);
    if (index == -1) {
      next.add(event.conversation);
    } else {
      next[index] = event.conversation;
    }
    conversations = sortRecentConversations(next);
    notifyListeners();
  }

  Future<void> disconnect() async {
    await _eventSubscription?.cancel();
    _eventSubscription = null;
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
    unawaited(_eventSubscription?.cancel());
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
    final root = conversation.workspaceRoot?.trim();
    if (root == null || root.isEmpty) continue;
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
