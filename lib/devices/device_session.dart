import 'dart:async';

import 'package:flutter/foundation.dart';

import '../gateway/gateway_client.dart';
import '../gateway/models.dart';
import '../gateway/transport.dart';
import 'device_models.dart';

enum DeviceConnectionState { offline, connecting, online, failed }

class DeviceSessionRuntimeLease {
  const DeviceSessionRuntimeLease._({
    required this.generation,
    required this.client,
  });

  final int generation;
  final GatewayClient client;
}

class DeviceSession extends ChangeNotifier {
  DeviceSession({
    required this.device,
    required this.clientFactory,
    this.autoReconnect = true,
    this.reconnectDelays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 10),
      Duration(seconds: 30),
    ],
  }) : assert(reconnectDelays.isNotEmpty);

  static const int conversationPageSize = 20;

  PairedDevice device;
  final GatewayClient Function() clientFactory;
  final bool autoReconnect;
  final List<Duration> reconnectDelays;
  GatewayClient? _client;
  GatewayEventWindow? _eventWindow;
  Timer? _reconnectTimer;
  final Map<GatewayProviderRoute, String?> _conversationCursors = {};
  bool _isLoadingMoreConversations = false;
  String? _loadMoreError;
  int _runtimeGeneration = 0;
  int _reconnectAttempt = 0;
  bool _reconnectEnabled = false;
  bool _disposed = false;
  DeviceConnectionState connectionState = DeviceConnectionState.offline;
  GatewayHandshake? handshake;
  String? error;
  List<ConversationSummary> conversations = const [];

  GatewayClient get client => _client!;
  DeviceSessionRuntimeLease? get runtimeLease {
    final currentClient = _client;
    if (connectionState != DeviceConnectionState.online ||
        currentClient == null) {
      return null;
    }
    return DeviceSessionRuntimeLease._(
      generation: _runtimeGeneration,
      client: currentClient,
    );
  }
  bool ownsRuntimeLease(DeviceSessionRuntimeLease lease) =>
      connectionState == DeviceConnectionState.online &&
      _ownsRuntime(lease.generation, lease.client);
  List<GatewayProvider> get conversationListProviders => handshake?.providers
          .where((provider) => provider.methods.contains('conversation.list'))
          .toList(growable: false) ??
      const [];
  List<GatewayProvider> get conversationSearchProviders => handshake?.providers
          .where((provider) => provider.methods.contains('conversation.search'))
          .toList(growable: false) ??
      const [];
  bool get canLoadMoreConversations =>
      connectionState == DeviceConnectionState.online &&
      _conversationCursors.values.any((cursor) => cursor != null);
  String get conversationCountLabel =>
      '${conversations.length}${canLoadMoreConversations ? '+' : ''}';
  bool get isLoadingMoreConversations => _isLoadingMoreConversations;
  String? get loadMoreError => _loadMoreError;

  Future<void> connect() {
    _reconnectEnabled = autoReconnect;
    _cancelReconnect(resetAttempt: true);
    return _connect();
  }

  Future<void> _connect() async {
    if (connectionState == DeviceConnectionState.connecting) return;
    final oldWindow = _eventWindow;
    final oldClient = _client;
    final generation = ++_runtimeGeneration;
    _eventWindow = null;
    _client = null;
    handshake = null;
    _resetConversationPagination();
    connectionState = DeviceConnectionState.connecting;
    error = null;
    notifyListeners();
    try {
      await oldWindow?.close();
    } catch (_) {}
    try {
      await oldClient?.close();
    } catch (_) {}
    if (generation != _runtimeGeneration) return;
    try {
      final client = clientFactory();
      _client = client;
      final window = client.openEventWindow();
      _eventWindow = window;
      final connectedHandshake = await client.connect();
      if (!_ownsRuntime(generation, client)) return;
      handshake = connectedHandshake;
      final hostDescriptor = connectedHandshake.deviceDescriptor;
      if (hostDescriptor != null) {
        device = device.withDescriptor(hostDescriptor);
      }
      var snapshotCursor = connectedHandshake.eventCursor;
      var isFirstPage = true;
      for (final provider in conversationListProviders) {
        final page = await client.listConversations(
          route: provider.route,
          limit: conversationPageSize,
        );
        if (!_ownsRuntime(generation, client)) return;
        if (isFirstPage) {
          snapshotCursor = page.snapshotCursor;
          isFirstPage = false;
        }
        conversations = mergeRoutedConversations(
          conversations,
          page.conversations,
        );
        _conversationCursors[provider.route] = page.nextCursor;
      }
      window.install(
        baselineCursor: connectedHandshake.eventCursor,
        snapshotCursor: snapshotCursor,
        onEvent: (event) {
          if (_ownsRuntime(generation, client)) {
            _applyEvent(event);
          }
        },
        onError: (Object value, StackTrace _) {
          unawaited(
            _failRuntime(
              '事件流异常：$value',
              cause: value,
              generation: generation,
              client: client,
            ),
          );
        },
      );
      connectionState = DeviceConnectionState.online;
      _reconnectAttempt = 0;
      notifyListeners();
    } catch (value) {
      if (generation != _runtimeGeneration) return;
      final connectionError = value.toString();
      final window = _eventWindow;
      final client = _client;
      final failureGeneration = ++_runtimeGeneration;
      _eventWindow = null;
      _client = null;
      handshake = null;
      _resetConversationPagination();
      error = connectionError;
      connectionState = DeviceConnectionState.failed;
      notifyListeners();
      try {
        await window?.close();
      } catch (_) {}
      try {
        await client?.close();
      } catch (_) {}
      if (isRetryableGatewayFailure(value)) {
        _scheduleReconnect(failureGeneration);
      }
    }
  }

  void _scheduleReconnect(int generation) {
    if (!_canReconnect(generation) || _reconnectTimer != null) return;
    final delayIndex = _reconnectAttempt.clamp(0, reconnectDelays.length - 1);
    final delay = reconnectDelays[delayIndex];
    _reconnectAttempt++;
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (_canReconnect(generation)) unawaited(_connect());
    });
  }

  bool _canReconnect(int generation) =>
      generation == _runtimeGeneration &&
      connectionState == DeviceConnectionState.failed &&
      _reconnectEnabled &&
      !_disposed;

  void _cancelReconnect({bool resetAttempt = false}) {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    if (resetAttempt) _reconnectAttempt = 0;
  }

  Future<void> loadMoreConversations() async {
    final client = _client;
    final pendingRoutes = _conversationCursors.entries
        .where((entry) => entry.value != null)
        .toList(growable: false);
    if (connectionState != DeviceConnectionState.online ||
        client == null ||
        pendingRoutes.isEmpty ||
        _isLoadingMoreConversations) {
      return;
    }

    final generation = _runtimeGeneration;
    _isLoadingMoreConversations = true;
    _loadMoreError = null;
    notifyListeners();
    try {
      final pages = await Future.wait([
        for (final entry in pendingRoutes)
          client.listConversations(
            route: entry.key,
            cursor: entry.value,
            limit: conversationPageSize,
          ),
      ]);
      if (!_ownsRuntime(generation, client)) return;
      for (var index = 0; index < pages.length; index++) {
        final page = pages[index];
        conversations = mergeRoutedConversations(
          conversations,
          page.conversations,
        );
        _conversationCursors[pendingRoutes[index].key] = page.nextCursor;
      }
      _loadMoreError = null;
    } catch (value) {
      if (!_ownsRuntime(generation, client)) return;
      _loadMoreError = value.toString();
    } finally {
      if (_ownsRuntime(generation, client)) {
        _isLoadingMoreConversations = false;
        notifyListeners();
      }
    }
  }

  bool _ownsRuntime(int generation, GatewayClient client) =>
      generation == _runtimeGeneration && identical(_client, client);

  void _resetConversationPagination() {
    conversations = const [];
    _conversationCursors.clear();
    _isLoadingMoreConversations = false;
    _loadMoreError = null;
  }

  Future<void> _failRuntime(
    String message, {
    required Object cause,
    required int generation,
    required GatewayClient client,
  }) async {
    if (!_ownsRuntime(generation, client)) return;
    final window = _eventWindow;
    final failureGeneration = ++_runtimeGeneration;
    _eventWindow = null;
    _client = null;
    handshake = null;
    _resetConversationPagination();
    error = message;
    connectionState = DeviceConnectionState.failed;
    notifyListeners();
    try {
      await window?.close();
    } catch (_) {}
    try {
      await client.close();
    } catch (_) {}
    if (isRetryableGatewayFailure(cause)) {
      _scheduleReconnect(failureGeneration);
    }
  }

  void _applyEvent(GatewayEvent event) {
    if (event is! ConversationUpsertedEvent) return;
    conversations = mergeRoutedConversations(
      conversations,
      [event.conversation],
    );
    notifyListeners();
  }

  Future<void> disconnect() async {
    _reconnectEnabled = false;
    _cancelReconnect(resetAttempt: true);
    final window = _eventWindow;
    final client = _client;
    _runtimeGeneration++;
    _eventWindow = null;
    _client = null;
    handshake = null;
    error = null;
    _resetConversationPagination();
    connectionState = DeviceConnectionState.offline;
    notifyListeners();
    try {
      await window?.close();
    } catch (_) {}
    try {
      await client?.close();
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectEnabled = false;
    _cancelReconnect(resetAttempt: true);
    _runtimeGeneration++;
    final window = _eventWindow;
    final client = _client;
    _eventWindow = null;
    _client = null;
    unawaited(window?.close());
    if (client != null) unawaited(client.close());
    super.dispose();
  }
}

List<ConversationSummary> sortRecentConversations(
  Iterable<ConversationSummary> values,
) {
  return values.toList(growable: false)
    ..sort(_compareRecentConversations);
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
    conversations.sort(_compareRecentConversations);
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

String conversationRoutingKey(ConversationSummary conversation) {
  final resource = conversation.wireResource;
  final deviceId = resource?['deviceId'];
  final providerPluginId = resource?['providerPluginId'];
  final providerInstanceId = resource?['providerInstanceId'];
  final nativeResourceId = resource?['nativeResourceId'];
  if (deviceId is String &&
      providerPluginId is String &&
      providerInstanceId is String &&
      nativeResourceId is String) {
    return '$deviceId\u0000$providerPluginId\u0000$providerInstanceId\u0000$nativeResourceId';
  }
  return '${conversation.providerId}\u0000${conversation.id}';
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
