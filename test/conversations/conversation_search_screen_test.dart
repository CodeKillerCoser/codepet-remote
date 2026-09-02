import 'dart:async';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/features/conversations/conversation_search_screen.dart';
import 'package:codepet_remote/features/home/remote_home_screen.dart';
import 'package:codepet_remote/core/ports/gateway_client.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Provider selection scopes home content and search requests', (tester) async {
    _useTallSurface(tester);
    final client = _SearchClient(
      providers: const [_primaryProvider, _secondaryProvider],
      listValues: {
        _primaryRoute: [_conversation(_primaryRoute, 'home-a', '首页 A', 5000)],
        _secondaryRoute: [_conversation(_secondaryRoute, 'home-b', '首页 B', 4000)],
      },
      onSearch: ({required GatewayProviderRoute route, required String searchTerm, required String? cursor, required int limit}) async {
        expect(searchTerm, 'needle');
        if (route == _primaryRoute) {
          return ConversationPage(
            conversations: [
              _conversation(_primaryRoute, 'shared', '旧结果', 1000),
              _conversation(_primaryRoute, 'shared', '去重后的结果', 1500),
              _conversation(_primaryRoute, 'alpha', 'Alpha', 2000),
            ],
            snapshotCursor: 'handshake',
          );
        }
        return ConversationPage(
          conversations: [
            _conversation(_secondaryRoute, 'beta', 'Beta', 3000),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = _session(client);
    await session.connect();
    final homeProjection = List<ConversationSummary>.from(session.conversations);
    await tester.pumpWidget(MaterialApp(home: _HomeHarness(session: session)));

    expect(find.text('首页 A'), findsOneWidget);
    expect(find.text('首页 B'), findsNothing);
    await tester.tap(find.byKey(Key('provider-${_secondaryRoute.key}')));
    await tester.pump();
    expect(find.text('首页 A'), findsNothing);
    expect(find.text('首页 B'), findsOneWidget);

    await tester.tap(find.byKey(const Key('home-search')));
    await _pumpAsync(tester);
    await tester.enterText(find.byKey(const Key('search-input')), 'needle');
    await tester.tap(find.byKey(const Key('search-submit')));
    await _pumpAsync(tester);

    expect(client.searchRequests.map((request) => request.route), [
      _secondaryRoute,
    ]);
    expect(find.text('1 个结果'), findsOneWidget);
    expect(find.text('旧结果'), findsNothing);
    expect(find.text('去重后的结果'), findsNothing);
    expect(find.text('Beta'), findsOneWidget);
    expect(session.conversations, homeProjection);

    Navigator.of(tester.element(find.byType(ConversationSearchScreen))).pop();
    await _pumpAsync(tester);
    expect(session.conversations, homeProjection);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('search pages from 20+ to an exact count and stays isolated', (tester) async {
    _useTallSurface(tester);
    final client = _SearchClient(
      providers: const [_primaryProvider],
      listValues: {
        _primaryRoute: [_conversation(_primaryRoute, 'home', '首页会话', 5000)],
      },
      onSearch: ({required GatewayProviderRoute route, required String searchTerm, required String? cursor, required int limit}) async {
        expect(limit, 20);
        if (cursor == null) {
          return ConversationPage(
            conversations: [
              for (var index = 0; index < 20; index++)
                _conversation(
                  route,
                  'result-$index',
                  '结果 $index',
                  3000 - index,
                ),
            ],
            nextCursor: 'search-next',
            snapshotCursor: 'handshake',
          );
        }
        expect(cursor, 'search-next');
        return ConversationPage(
          conversations: [
            _conversation(route, 'result-20', '结果 20', 1000),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = _session(client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: ConversationSearchScreen(session: session)),
    );

    await tester.enterText(find.byKey(const Key('search-input')), 'page');
    await tester.tap(find.byKey(const Key('search-submit')));
    await _pumpAsync(tester);

    expect(find.text('20+ 个结果'), findsOneWidget);
    expect(find.text('结果 20'), findsNothing);
    expect(session.conversations.single.title, '首页会话');

    await tester.tap(find.byKey(const Key('search-show-more')));
    await _pumpAsync(tester);

    expect(client.searchRequests.last.cursor, 'search-next');
    expect(find.text('21 个结果'), findsOneWidget);
    expect(find.text('结果 20'), findsOneWidget);
    expect(session.conversations.single.title, '首页会话');
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('disconnect and reconnect discard old results and late pages', (tester) async {
    _useTallSurface(tester);
    final latePage = Completer<ConversationPage>();
    var oldSearches = 0;
    final oldClient = _SearchClient(
      providers: const [_primaryProvider],
      onSearch: ({required GatewayProviderRoute route, required String searchTerm, required String? cursor, required int limit}) {
        oldSearches++;
        if (oldSearches == 1) {
          return Future.value(ConversationPage(
            conversations: [
              _conversation(route, 'old-visible', '旧运行结果', 2000),
            ],
            snapshotCursor: 'handshake',
          ));
        }
        return latePage.future;
      },
    );
    final newClient = _SearchClient(
      providers: const [_primaryProvider],
      onSearch: _unusedSearch,
    );
    final clients = [oldClient, newClient];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: const PairedDevice(
        deviceId: 'host-one',
        displayName: 'Host',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: () => clients[factoryCalls++],
    );
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: ConversationSearchScreen(session: session)),
    );

    await tester.enterText(find.byKey(const Key('search-input')), 'old');
    await tester.tap(find.byKey(const Key('search-submit')));
    await _pumpAsync(tester);
    expect(find.text('旧运行结果'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('search-input')), 'late');
    await tester.tap(find.byKey(const Key('search-submit')));
    await tester.pump();
    expect(oldSearches, 2);

    unawaited(session.disconnect());
    await tester.pump();
    expect(find.byKey(const Key('search-offline')), findsOneWidget);
    expect(find.text('旧运行结果'), findsNothing);

    await session.connect();
    await tester.pump();
    latePage.complete(ConversationPage(
      conversations: [
        _conversation(_primaryRoute, 'late-old', '迟到的旧结果', 3000),
      ],
      snapshotCursor: 'handshake',
    ));
    await _pumpAsync(tester);

    expect(factoryCalls, 2);
    expect(find.text('旧运行结果'), findsNothing);
    expect(find.text('迟到的旧结果'), findsNothing);
    expect(find.byKey(const Key('search-results')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });

  testWidgets('search explains unsupported Providers and rejects an empty term', (tester) async {
    final unsupportedClient = _SearchClient(
      providers: const [_listOnlyProvider],
      onSearch: _unusedSearch,
    );
    final unsupportedSession = _session(unsupportedClient);
    await unsupportedSession.connect();
    await tester.pumpWidget(
      MaterialApp(home: ConversationSearchScreen(session: unsupportedSession)),
    );
    expect(find.byKey(const Key('search-unsupported')), findsOneWidget);
    expect(find.textContaining('conversation.search'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    unsupportedSession.dispose();

    final supportedClient = _SearchClient(
      providers: const [_primaryProvider],
      onSearch: _unusedSearch,
    );
    final supportedSession = _session(supportedClient);
    await supportedSession.connect();
    await tester.pumpWidget(
      MaterialApp(home: ConversationSearchScreen(session: supportedSession)),
    );
    await tester.tap(find.byKey(const Key('search-submit')));
    await tester.pump();
    expect(find.text('请输入搜索关键词'), findsOneWidget);
    expect(supportedClient.searchRequests, isEmpty);
    await tester.pumpWidget(const SizedBox());
    supportedSession.dispose();
  });

  testWidgets('search retries an error and then shows an empty result', (tester) async {
    var attempts = 0;
    final client = _SearchClient(
      providers: const [_primaryProvider],
      onSearch: ({required GatewayProviderRoute route, required String searchTerm, required String? cursor, required int limit}) async {
        attempts++;
        if (attempts == 1) throw StateError('search unavailable');
        return const ConversationPage(
          conversations: [],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = _session(client);
    await session.connect();
    await tester.pumpWidget(
      MaterialApp(home: ConversationSearchScreen(session: session)),
    );

    await tester.enterText(find.byKey(const Key('search-input')), 'nothing');
    await tester.tap(find.byKey(const Key('search-submit')));
    await _pumpAsync(tester);
    expect(find.byKey(const Key('search-error')), findsOneWidget);
    expect(find.textContaining('search unavailable'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await _pumpAsync(tester);
    expect(find.byKey(const Key('search-empty')), findsOneWidget);
    expect(client.searchRequests, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    session.dispose();
  });
}

void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1200, 4000);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Future<void> _pumpAsync(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
  await tester.pump();
}

DeviceSession _session(_SearchClient client) => DeviceSession(
      device: const PairedDevice(
        deviceId: 'host-one',
        displayName: 'Host',
        connectionKind: DeviceConnectionKind.demo,
      ),
      clientFactory: () => client,
    );

class _HomeHarness extends StatelessWidget {
  const _HomeHarness({required this.session});

  final DeviceSession session;

  @override
  Widget build(BuildContext context) => RemoteHomeScreen(
        sessions: [session],
        selectedIndex: 0,
        onSelectDevice: (_) {},
        onAddDevice: () {},
        onOpenSettings: () {},
      );
}

ConversationSummary _conversation(
  GatewayProviderRoute route,
  String nativeId,
  String title,
  int updatedAt,
) {
  final resource = {
    ...route.toJson(),
    'nativeResourceId': nativeId,
  };
  return ConversationSummary(
    id: '${route.key}\u0000$nativeId',
    providerId: route.providerInstanceId,
    title: title,
    preview: 'preview $nativeId',
    status: ConversationStatus.idle,
    permissionLevel: PermissionLevel.readOnly,
    workspaceRoot: '/repo',
    createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    wireResource: resource,
  );
}

typedef _SearchHandler = Future<ConversationPage> Function({
  required GatewayProviderRoute route,
  required String searchTerm,
  required String? cursor,
  required int limit,
});

Future<ConversationPage> _unusedSearch({
  required GatewayProviderRoute route,
  required String searchTerm,
  required String? cursor,
  required int limit,
}) => throw StateError('search should not run');

class _SearchRequest {
  const _SearchRequest({
    required this.route,
    required this.searchTerm,
    required this.cursor,
    required this.limit,
  });

  final GatewayProviderRoute route;
  final String searchTerm;
  final String? cursor;
  final int limit;
}

class _SearchClient implements GatewayClient {
  _SearchClient({
    required this.providers,
    required this.onSearch,
    this.listValues = const {},
  });

  final List<GatewayProvider> providers;
  final _SearchHandler onSearch;
  final Map<GatewayProviderRoute, List<ConversationSummary>> listValues;
  final List<_SearchRequest> searchRequests = [];
  final StreamController<GatewayEvent> controller =
      StreamController<GatewayEvent>.broadcast();

  @override
  Stream<GatewayEvent> get events => controller.stream;

  @override
  String? get latestEventCursor => 'handshake';

  @override
  GatewayEventWindow openEventWindow() =>
      GatewayEventWindow.forStream('handshake', events);

  @override
  Future<GatewayHandshake> connect() async => GatewayHandshake(
        protocolVersion: 1,
        serverName: 'Test Host',
        serverVersion: '1',
        providers: providers,
        eventCursor: 'handshake',
        deviceId: 'host-one',
      );

  @override
  Future<ConversationPage> listConversations({
    required GatewayProviderRoute route,
    String? cursor,
    int limit = 50,
  }) async => ConversationPage(
        conversations: listValues[route] ?? const [],
        snapshotCursor: 'handshake',
      );

  @override
  Future<ConversationPage> searchConversations({
    required GatewayProviderRoute route,
    required String searchTerm,
    String? cursor,
    int limit = 50,
  }) {
    searchRequests.add(_SearchRequest(
      route: route,
      searchTerm: searchTerm,
      cursor: cursor,
      limit: limit,
    ));
    return onSearch(
      route: route,
      searchTerm: searchTerm,
      cursor: cursor,
      limit: limit,
    );
  }

  @override
  Future<ConversationSnapshot> getConversation(
    ConversationSummary conversation,
  ) async {
    return ConversationSnapshot(
      detail: ConversationDetail(summary: conversation),
      snapshotCursor: 'handshake',
    );
  }

  @override
  Future<ConversationSummary> createConversation({required GatewayProviderRoute route, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot}) => throw UnimplementedError();

  @override
  Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();

  @override
  Future<void> close() async {
    if (!controller.isClosed) unawaited(controller.close());
  }
}

const _primaryRoute = GatewayProviderRoute(
  deviceId: 'host-one',
  providerPluginId: 'dev.codepet.codex',
  providerInstanceId: 'codex-work',
);

const _secondaryRoute = GatewayProviderRoute(
  deviceId: 'host-one',
  providerPluginId: 'dev.codepet.claude',
  providerInstanceId: 'claude-work',
);

const _primaryProvider = GatewayProvider(
  route: _primaryRoute,
  providerType: 'dev.codepet.codex',
  displayName: 'Codex Work',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'codex', displayName: 'Codex'),
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.search', 'conversation.get'],
  ),
);

const _secondaryProvider = GatewayProvider(
  route: _secondaryRoute,
  providerType: 'dev.codepet.claude',
  displayName: 'Claude Work',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'claude', displayName: 'Claude'),
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.search', 'conversation.get'],
  ),
);

const _listOnlyProvider = GatewayProvider(
  route: _primaryRoute,
  providerType: 'dev.codepet.codex',
  displayName: 'Codex Work',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'codex', displayName: 'Codex'),
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.get'],
  ),
);
