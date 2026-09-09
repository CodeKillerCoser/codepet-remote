import 'dart:async';

import 'package:codepet_remote/core/domain/paired_device.dart';
import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/application/errors/application_failures.dart';
import 'package:codepet_remote/application/ports/gateway_client.dart';
import 'package:codepet_remote/application/sync/gateway_event_window.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sorts recent conversations without treating cwd as project identity', () {
    final old = _conversation('old', '/repo/a', 1000);
    final recent = _conversation('recent', '/repo/a', 3000);
    final other = _conversation('other', '/repo/b', 2000);
    final unscoped = _conversation('unscoped', null, 4000);
    expect(
      sortRecentConversations([old, unscoped, other, recent])
          .map((item) => item.id),
      ['unscoped', 'recent', 'other', 'old'],
    );
  });

  test('uses stable routed tie-breakers for conversations', () {
    final beta = _conversation('beta', '/repo/a', 3000);
    final alpha = _conversation('alpha', '/repo/a', 3000);

    expect(
      sortRecentConversations([beta, alpha]).map((item) => item.id),
      ['alpha', 'beta'],
    );
  });

  test('an equal-timestamp projection replaces the earlier routed value', () {
    final earlier = _routedConversation(
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/logical/project',
      updatedAt: 2000,
      title: '旧标题',
    );
    final later = _routedConversation(
      nativeId: 'shared-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/logical/project',
      updatedAt: 2000,
      title: '新标题',
    );

    expect(
      deduplicateRoutedConversations([earlier, later]).single.title,
      '新标题',
    );
  });

  test('provider.changed replaces its summary before lazily describing a new revision',
      () async {
    final description = Completer<GatewayProvider>();
    final client = _FakeClient(
      const [],
      onDescribeProvider: (_) => description.future,
    );
    final session = DeviceSession(
      device: _device('provider-change'),
      clientFactory: () => client,
    );
    await session.connect();

    client.emit(const GatewayProviderChangedEvent(
      eventCursor: 'provider-2',
      provider: GatewayProvider(
        id: _primaryRoute,
        displayName: 'Codex Updated',
        status: ProviderStatus.ready,
        runtimeVersion: '0.152.0',
        capabilities: GatewayCapabilities(
          revision: 'test-2',
          methods: [],
        ),
        capabilitiesLoaded: false,
      ),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.selectedProvider?.displayName, 'Codex Updated');
    expect(session.selectedProvider?.runtimeVersion, '0.152.0');
    expect(session.selectedProvider?.capabilitiesLoaded, isFalse);
    expect(client.describeProviderIds, [_primaryRoute]);

    description.complete(const GatewayProvider(
      id: _primaryRoute,
      displayName: 'Codex Updated',
      status: ProviderStatus.ready,
      runtimeVersion: '0.152.0',
      capabilities: GatewayCapabilities(
        revision: 'test-2',
        methods: ['conversation.list', 'conversation.get', 'turn.send'],
        turnSend: TurnSendCapabilities(),
      ),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.selectedProvider?.capabilitiesLoaded, isTrue);
    expect(session.selectedProvider?.methods, contains('turn.send'));
    session.dispose();
  });

  test('heartbeat updates only the matching provider and discards older generations', () async {
    const second = GatewayProvider(id: 'second', displayName: 'Second',
      status: ProviderStatus.ready, connectionStatus: 'online', generation: 2,
      capabilities: GatewayCapabilities(revision: 'second-1', methods: ['conversation.list']));
    const offline = GatewayProvider(id: 'second', displayName: 'Second',
      status: ProviderStatus.ready, connectionStatus: 'offline', generation: 2,
      capabilitiesLoaded: false,
      capabilities: GatewayCapabilities(revision: 'second-1', methods: []));
    final client = _FakeClient(const [], providers: [_listProvider, second]);
    final session = DeviceSession(device: _device('heartbeat-providers'), clientFactory: () => client);
    await session.connect();
    client.snapshots.add([_listProvider, offline]);
    await Future<void>.delayed(Duration.zero);
    expect(session.handshake!.providers.first.id, _primaryRoute);
    expect(session.handshake!.providers.first.displayName, 'Codex Work');
    expect(session.handshake!.providers.last.isAvailable, isFalse);
    expect(session.handshake!.providers.last.methods, ['conversation.list']);
    client.emit(const GatewayProviderChangedEvent(eventCursor: 'old-runtime',
      provider: GatewayProvider(id: 'second', displayName: 'Stale', status: ProviderStatus.ready,
        connectionStatus: 'online', generation: 1,
        capabilities: GatewayCapabilities(revision: 'old', methods: []))));
    await Future<void>.delayed(Duration.zero);
    expect(session.handshake!.providers.last.connectionStatus, 'offline');
    expect(client.describeProviderIds, isEmpty);
    client.snapshots.add([offline]);
    await Future<void>.delayed(Duration.zero);
    expect(session.handshake!.providers.single.id, 'second');
    expect(session.selectedProvider?.id, 'second');
    session.dispose();
  });

  test('provider becoming ready after connection loads its projects', () async {
    final waiting = GatewayProvider(id: _primaryRoute, displayName: 'Starting',
      status: ProviderStatus.connecting, connectionStatus: 'online',
      capabilities: _projectProvider.capabilities);
    final client = _ProjectFakeClient(projects: [_gatewayProject()], conversations: [], providers: [waiting]);
    final session = DeviceSession(device: _device('late-projects'), clientFactory: () => client);
    await session.connect();
    expect(client.projectListCalls, 0);
    client.snapshots.add([_projectProvider]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(client.projectListCalls, 1);
    expect(session.projects.single.name, 'Project One');
    session.dispose();
  });

  test('Starting defers description and lists until one Ready snapshot with the same revision', () async {
    final description = Completer<GatewayProvider>();
    const starting = GatewayProvider(id: _primaryRoute, displayName: 'Codex',
      status: ProviderStatus.connecting, connectionStatus: 'online',
      capabilitiesLoaded: false,
      capabilities: GatewayCapabilities(revision: 'projects-1', methods: []));
    const ready = GatewayProvider(id: _primaryRoute, displayName: 'Codex',
      status: ProviderStatus.ready, connectionStatus: 'online',
      capabilitiesLoaded: false,
      capabilities: GatewayCapabilities(revision: 'projects-1', methods: []));
    final client = _ProjectFakeClient(projects: [_gatewayProject()], conversations: [],
      providers: [starting], onDescribeProvider: (_) => description.future);
    final session = DeviceSession(device: _device('startup-barrier'), clientFactory: () => client);
    await session.connect();
    expect(client.describeProviderIds, isEmpty);
    expect(client.projectListCalls, 0);
    expect(client.listRequests, isEmpty);
    client.snapshots.add([starting]);
    await Future<void>.delayed(Duration.zero);
    expect(client.describeProviderIds, isEmpty);
    client.snapshots.add([ready]);
    await Future<void>.delayed(Duration.zero);
    expect(client.describeProviderIds, [_primaryRoute]);
    expect(client.projectListCalls, 0);
    expect(client.listRequests, isEmpty);
    client.snapshots.add([ready]);
    await Future<void>.delayed(Duration.zero);
    expect(client.describeProviderIds, [_primaryRoute]);
    description.complete(_projectProvider);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(client.projectListCalls, 1);
    expect(client.listRequests, hasLength(1));
    expect(session.projects.single.name, 'Project One');
    client.snapshots.add([ready]);
    await Future<void>.delayed(Duration.zero);
    expect(client.describeProviderIds, [_primaryRoute]);
    expect(client.projectListCalls, 1);
    expect(client.listRequests, hasLength(1));
    session.dispose();
  });

  test('provider without projects uses all conversations through pagination',
      () async {
    final client = _FakeClient([], nextCursor: 'next-page');
    final session = DeviceSession(
      device: _device('without-projects'),
      clientFactory: () => client,
    );

    await session.connect();

    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.selectedProviderSupportsProjects, isFalse);
    expect(client.listRequests.single.projectFilter, isA<AllConversationFilter>());

    await session.loadMoreConversations();

    expect(client.listRequests, hasLength(2));
    expect(client.listRequests.last.cursor, 'next-page');
    expect(client.listRequests.last.projectFilter, isA<AllConversationFilter>());
    session.dispose();
  });

  test('loads projects independently and uses explicit conversation scopes',
      () async {
    final project = _gatewayProject();
    final standalone = _routedConversation(
      nativeId: 'standalone',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/same/cwd',
      updatedAt: 3000,
    );
    final projectConversation = _routedConversation(
      nativeId: 'project-conversation',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/same/cwd',
      updatedAt: 2000,
      project: project.resource,
    );
    final client = _ProjectFakeClient(
      projects: [project],
      conversations: [standalone, projectConversation],
    );
    final session = DeviceSession(
      device: _device('projects'),
      clientFactory: () => client,
    );

    await session.connect();

    expect(session.selectedProviderSupportsProjects, isTrue);
    expect(session.selectedProviderProjects, [project]);
    expect(session.selectedProviderRecentConversations, isEmpty);
    expect(session.selectedProviderStandaloneConversations, [standalone]);
    expect(session.selectedProviderConversations, [standalone]);
    expect(client.listRequests.single.projectFilter,
        isA<StandaloneConversationFilter>());

    await session.ensureProjectConversations(project);

    expect(session.conversationsForProject(project), [projectConversation]);
    expect(client.listRequests.last.projectFilter,
        isA<ProjectConversationFilter>());
    expect(
      (client.listRequests.last.projectFilter as ProjectConversationFilter)
          .project,
      project.resource,
    );
    session.dispose();
  });

  test('runtime metadata preserves project membership when it has no project', () async {
    final project = _gatewayProject();
    ConversationSummary metadata(int timestamp, RoutedResourceId? membership) =>
        _routedConversation(
          nativeId: 'resumed', providerPluginId: 'dev.codepet.codex',
          providerInstanceId: _primaryRoute, workspaceRoot: '/worktree',
          updatedAt: timestamp, title: 'title-$timestamp', project: membership,
        );
    final client = _ProjectFakeClient(
      projects: [project], conversations: [metadata(3000, project.resource)],
    );
    final session = DeviceSession(device: _device('resume-project'), clientFactory: () => client);
    addTearDown(session.dispose);
    await session.connect();
    await session.ensureProjectConversations(project);
    for (final timestamp in [2000, 4000]) {
      client.emit(ConversationUpsertedEvent(
        eventCursor: 'metadata-$timestamp', conversation: metadata(timestamp, null),
      ));
      await pumpEventQueue();
      await session.ensureProjectConversations(project);
      expect(session.conversationsForProject(project).single.project, project.resource);
      expect(session.conversations.single.title, 'title-$timestamp');
    }
    const moved = RoutedResourceId(providerId: _primaryRoute, nativeResourceId: 'project-2');
    client.emit(ConversationUpsertedEvent(
      eventCursor: 'moved', conversation: metadata(5000, moved),
    ));
    await pumpEventQueue();
    expect(session.conversationsForProject(project), isEmpty);
    expect(session.conversations.single.project, moved);
  });

  test('project changed refreshes created and updated values and removes deletes',
      () async {
    final initial = _gatewayProject();
    final client = _ProjectFakeClient(
      projects: [initial],
      conversations: const [],
    );
    final session = DeviceSession(
      device: _device('project-events'),
      clientFactory: () => client,
    );
    await session.connect();

    final updated = GatewayProject(
      resource: initial.resource,
      name: 'Renamed',
      roots: initial.roots,
      metadata: initial.metadata,
      position: initial.position,
      createdAt: initial.createdAt,
      updatedAt: initial.updatedAt.add(const Duration(seconds: 1)),
    );
    client.projects[0] = updated;
    client.emit(ProjectChangedEvent(
      eventCursor: 'project-updated',
      project: initial.resource,
      changeType: ProjectChangeType.updated,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.selectedProviderProjects.single.name, 'Renamed');

    client.projects.clear();
    client.emit(ProjectChangedEvent(
      eventCursor: 'project-deleted',
      project: initial.resource,
      changeType: ProjectChangeType.deleted,
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.selectedProviderProjects, isEmpty);
    expect(client.projectListCalls, 3);
    session.dispose();
  });

  test('project changes arriving during refresh are drained', () async {
    final initial = _gatewayProject();
    final client = _ProjectFakeClient(
      projects: [initial],
      conversations: const [],
    );
    final session = DeviceSession(
      device: _device('project-event-drain'),
      clientFactory: () => client,
    );
    await session.connect();

    final firstRefresh = Completer<ProjectPage>();
    client.nextProjectPage = firstRefresh;
    client.emit(ProjectChangedEvent(
      eventCursor: 'project-first',
      project: initial.resource,
      changeType: ProjectChangeType.updated,
    ));
    await Future<void>.delayed(Duration.zero);

    final newest = GatewayProject(
      resource: initial.resource,
      name: 'Newest',
      roots: initial.roots,
      metadata: initial.metadata,
      position: initial.position,
      createdAt: initial.createdAt,
      updatedAt: initial.updatedAt.add(const Duration(seconds: 2)),
    );
    client.projects[0] = newest;
    client.emit(ProjectChangedEvent(
      eventCursor: 'project-second',
      project: initial.resource,
      changeType: ProjectChangeType.updated,
    ));
    firstRefresh.complete(ProjectPage(
      projects: [initial],
      snapshotCursor: 'project-first',
    ));
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(session.selectedProviderProjects.single.name, 'Newest');
    expect(client.projectListCalls, 3);
    session.dispose();
  });

  test('loads two cursor pages with an explicit small page limit', () async {
    final client = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [_conversation('first', '/repo', 1000)],
            nextCursor: 'page-2',
            snapshotCursor: 'handshake',
          );
        }
        expect(cursor, 'page-2');
        return ConversationPage(
          conversations: [_conversation('second', '/repo', 2000)],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('paged'),
      clientFactory: () => client,
    );

    await session.connect();

    expect(client.listRequests, hasLength(1));
    expect(client.listRequests.single.cursor, isNull);
    expect(
      client.listRequests.single.limit,
      DeviceSession.conversationPageSize,
    );
    expect(DeviceSession.conversationPageSize, 20);
    expect(session.canLoadMoreConversations, isTrue);

    await session.loadMoreConversations();

    expect(
      session.conversations.map((conversation) => conversation.id),
      ['second', 'first'],
    );
    expect(client.listRequests, hasLength(2));
    expect(client.listRequests.last.cursor, 'page-2');
    expect(client.listRequests.last.limit, DeviceSession.conversationPageSize);
    expect(session.canLoadMoreConversations, isFalse);

    await session.loadMoreConversations();
    expect(client.listRequests, hasLength(2));
    session.dispose();
  });

  test('keeps independent cursors and merges routed Provider pages', () async {
    final client = _FakeClient(
      const [],
      providers: const [_listProvider, _secondaryListProvider],
      onListConversations: ({required String route, required String? cursor, required int limit}) async {
        if (route == _primaryRoute && cursor == null) {
          return ConversationPage(
            conversations: [
              _routedConversation(
                nativeId: 'shared',
                providerPluginId: 'provider',
                providerInstanceId: route,
                workspaceRoot: '/repo',
                updatedAt: 1000,
              ),
              _routedConversation(
                nativeId: 'alpha',
                providerPluginId: 'provider',
                providerInstanceId: route,
                workspaceRoot: '/repo',
                updatedAt: 2000,
              ),
            ],
            nextCursor: 'codex-next',
            snapshotCursor: 'handshake',
          );
        }
        if (route == _secondaryRoute && cursor == null) {
          return ConversationPage(
            conversations: [
              _routedConversation(
                nativeId: 'beta',
                providerPluginId: 'provider',
                providerInstanceId: route,
                workspaceRoot: '/repo',
                updatedAt: 3000,
              ),
            ],
            snapshotCursor: 'handshake',
          );
        }
        expect(route, _primaryRoute);
        expect(cursor, 'codex-next');
        return ConversationPage(
          conversations: [
            _routedConversation(
              nativeId: 'shared',
              providerPluginId: 'provider',
              providerInstanceId: route,
              workspaceRoot: '/repo',
              updatedAt: 4000,
              title: 'new shared',
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('multi-route'),
      clientFactory: () => client,
    );

    await session.connect();

    expect(client.listRequests.map((request) => request.route), [
      _primaryRoute,
      _secondaryRoute,
    ]);
    expect(
      session.conversations.map((conversation) => conversation.title),
      ['beta', 'alpha', 'shared'],
    );
    expect(session.canLoadMoreConversations, isTrue);

    await session.loadMoreConversations();

    expect(client.listRequests, hasLength(3));
    expect(client.listRequests.last.route, _primaryRoute);
    expect(client.listRequests.last.cursor, 'codex-next');
    expect(session.conversations, hasLength(3));
    expect(session.conversations.first.title, 'new shared');
    expect(session.canLoadMoreConversations, isFalse);
    session.dispose();
  });

  test('marks a loaded count approximate until every route is exhausted', () async {
    final client = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [
              for (var index = 0; index < 20; index++)
                _routedConversation(
                  nativeId: 'initial-$index',
                  providerPluginId: 'provider',
                  providerInstanceId: route,
                  workspaceRoot: '/repo',
                  updatedAt: 1000 - index,
                ),
            ],
            nextCursor: 'next',
            snapshotCursor: 'handshake',
          );
        }
        return ConversationPage(
          conversations: [
            _routedConversation(
              nativeId: 'last',
              providerPluginId: 'provider',
              providerInstanceId: route,
              workspaceRoot: '/repo',
              updatedAt: 1,
            ),
          ],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('count'),
      clientFactory: () => client,
    );

    await session.connect();
    expect(session.conversationCountLabel, '20+');

    await session.loadMoreConversations();
    expect(session.conversationCountLabel, '21');
    session.dispose();
  });

  test('suppresses concurrent load-more requests', () async {
    final nextPage = Completer<ConversationPage>();
    final client = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) {
        if (cursor == null) {
          return Future.value(
            const ConversationPage(
              conversations: [],
              nextCursor: 'page-2',
              snapshotCursor: 'handshake',
            ),
          );
        }
        return nextPage.future;
      },
    );
    final session = DeviceSession(
      device: _device('concurrent'),
      clientFactory: () => client,
    );
    await session.connect();

    final firstRequest = session.loadMoreConversations();
    final duplicateRequest = session.loadMoreConversations();
    await duplicateRequest;

    expect(session.isLoadingMoreConversations, isTrue);
    expect(client.listRequests, hasLength(2));

    nextPage.complete(
      ConversationPage(
        conversations: [_conversation('next', '/repo', 2000)],
        snapshotCursor: 'handshake',
      ),
    );
    await firstRequest;

    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.conversations.single.id, 'next');
    session.dispose();
  });

  test('keeps the page cursor and existing data after failure for retry', () async {
    var nextPageAttempts = 0;
    final client = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [_conversation('first', '/repo', 1000)],
            nextCursor: 'retry-page',
            snapshotCursor: 'handshake',
          );
        }
        nextPageAttempts++;
        if (nextPageAttempts == 1) {
          throw StateError('page failed');
        }
        return ConversationPage(
          conversations: [_conversation('recovered', '/repo', 2000)],
          snapshotCursor: 'handshake',
        );
      },
    );
    final session = DeviceSession(
      device: _device('retry-page'),
      clientFactory: () => client,
    );
    await session.connect();

    await session.loadMoreConversations();

    expect(session.conversations.single.id, 'first');
    expect(session.canLoadMoreConversations, isTrue);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, contains('page failed'));

    await session.loadMoreConversations();

    expect(nextPageAttempts, 2);
    expect(session.loadMoreError, isNull);
    expect(session.canLoadMoreConversations, isFalse);
    expect(
      session.conversations.map((conversation) => conversation.id),
      ['recovered', 'first'],
    );
    session.dispose();
  });

  test('a stale page cannot overwrite a newer routed event', () async {
    final nextPage = Completer<ConversationPage>();
    final client = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) {
        if (cursor == null) {
          return Future.value(
            const ConversationPage(
              conversations: [],
              nextCursor: 'page-2',
              snapshotCursor: 'handshake',
            ),
          );
        }
        return nextPage.future;
      },
    );
    final session = DeviceSession(
      device: _device('event-race'),
      clientFactory: () => client,
    );
    await session.connect();

    final request = session.loadMoreConversations();
    client.emit(
      ConversationUpsertedEvent(
        eventCursor: 'event-2',
        conversation: _routedConversation(
          nativeId: 'shared',
          providerPluginId: 'dev.codepet.codex',
          providerInstanceId: 'codex-work',
          workspaceRoot: '/repo',
          updatedAt: 3000,
          title: 'new event',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    nextPage.complete(
      ConversationPage(
        conversations: [
          _routedConversation(
            nativeId: 'shared',
            providerPluginId: 'dev.codepet.codex',
            providerInstanceId: 'codex-work',
            workspaceRoot: '/repo',
            updatedAt: 2000,
            title: 'stale page',
          ),
        ],
        snapshotCursor: 'handshake',
      ),
    );
    await request;

    expect(session.conversations, hasLength(1));
    expect(session.conversations.single.title, 'new event');
    expect(
      session.conversations.single.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
    );
    session.dispose();
  });

  test('a routed event refreshes title without regressing list ordering time', () async {
    final original = _routedConversation(
      nativeId: 'renamed',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: 'codex-work',
      workspaceRoot: '/repo',
      updatedAt: 3000,
      title: '旧标题',
    );
    final client = _FakeClient([original]);
    final session = DeviceSession(
      device: _device('title-event'),
      clientFactory: () => client,
    );
    await session.connect();

    client.emit(
      ConversationUpsertedEvent(
        eventCursor: 'event-2',
        conversation: _routedConversation(
          nativeId: 'renamed',
          providerPluginId: 'dev.codepet.codex',
          providerInstanceId: 'codex-work',
          workspaceRoot: '/repo',
          updatedAt: 2000,
          title: '新标题',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.title, '新标题');
    expect(session.conversations.single.updatedAt, original.updatedAt);
    session.dispose();
  });

  test('activity marks a conversation unread and metadata events preserve it',
      () async {
    final conversation = _routedConversation(
      nativeId: 'unread-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    final client = _FakeClient([conversation]);
    final session = DeviceSession(
      device: _device('unread-event'),
      clientFactory: () => client,
    );
    await session.connect();

    client.emit(ConversationActivityChangedEvent(
      eventCursor: 'activity-event',
      conversationId: conversationRoutingKey(conversation),
      activityVersion: 'activity-1',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.readState.unread, isTrue);
    expect(
      session.conversations.single.readState.activityVersion,
      'activity-1',
    );

    client.emit(ConversationUpsertedEvent(
      eventCursor: 'metadata-event',
      conversation: _routedConversation(
        nativeId: 'unread-thread',
        providerPluginId: 'dev.codepet.codex',
        providerInstanceId: _primaryRoute,
        workspaceRoot: '/repo',
        updatedAt: 2000,
        title: '新标题',
      ),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.title, '新标题');
    expect(session.conversations.single.readState.unread, isTrue);
    session.dispose();
  });

  test('accepts current turn completion behind metadata timestamp', () async {
    final conversation = _routedConversation(
      nativeId: 'terminal-thread', providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute, workspaceRoot: '/repo', updatedAt: 1000,
    );
    final running = _turnFor(conversation, TurnStatus.running, 2000);
    final client = _FakeClient([conversation.withTurn(running)]);
    final session = DeviceSession(
      device: _device('terminal-metadata'), clientFactory: () => client,
    );
    await session.connect();
    client.emit(ConversationUpsertedEvent(
      eventCursor: 'newer-metadata',
      conversation: conversation.withTurn(_turnFor(conversation, TurnStatus.running, 4000)),
    ));
    client.emit(TurnUpsertedEvent(
      eventCursor: 'completed',
      turn: _turnFor(conversation, TurnStatus.completed, 3000),
    ));
    await Future<void>.delayed(Duration.zero);
    expect(session.conversations.single.status, ConversationStatus.idle);
    expect(session.conversations.single.activeTurn, isNull);
    expect(session.conversations.single.updatedAt,
        DateTime.fromMillisecondsSinceEpoch(4000, isUtc: true));
    session.dispose();
  });

  test('turn events keep the conversation list running state live', () async {
    final conversation = _routedConversation(
      nativeId: 'live-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    final client = _FakeClient([conversation]);
    final session = DeviceSession(
      device: _device('live-turn'),
      clientFactory: () => client,
    );
    await session.connect();

    client.emit(TurnUpsertedEvent(
      eventCursor: 'running',
      turn: _turnFor(conversation, TurnStatus.running, 2000),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.status, ConversationStatus.running);
    expect(session.conversations.single.activeTurn?.status, TurnStatus.running);

    client.emit(TurnOutputDeltaEvent(
      eventCursor: 'delta-1',
      providerId: conversation.providerId,
      conversationId: conversationRoutingKey(conversation),
      turnId: 'turn-live',
      itemId: 'assistant',
      contentId: 'assistant:text',
      kind: 'text',
      delta: '实时',
    ));
    client.emit(TurnOutputDeltaEvent(
      eventCursor: 'delta-2',
      providerId: conversation.providerId,
      conversationId: conversationRoutingKey(conversation),
      turnId: 'turn-live',
      itemId: 'assistant',
      contentId: 'assistant:text',
      kind: 'text',
      delta: '内容',
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.preview, '实时内容');

    client.emit(TurnUpsertedEvent(
      eventCursor: 'completed',
      turn: _turnFor(conversation, TurnStatus.completed, 3000),
    ));
    await Future<void>.delayed(Duration.zero);

    expect(session.conversations.single.status, ConversationStatus.idle);
    expect(session.conversations.single.activeTurn, isNull);
    expect(
      session.conversations.single.updatedAt,
      DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
    );
    session.dispose();
  });

  testWidgets('coalesces a burst of output deltas into one frame notification',
      (tester) async {
    final conversation = _routedConversation(
      nativeId: 'coalesced-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    final client = _FakeClient([conversation]);
    final session = DeviceSession(
      device: _device('coalesced-deltas'),
      clientFactory: () => client,
    );
    await session.connect();
    var sessionNotifications = 0;
    session.addListener(() => sessionNotifications++);

    for (var index = 0; index < 20; index++) {
      client.emit(TurnOutputDeltaEvent(
        eventCursor: 'delta-$index',
        providerId: conversation.providerId,
        conversationId: conversationRoutingKey(conversation),
        turnId: 'turn-live',
        itemId: 'assistant',
        contentId: 'assistant:text',
        kind: 'text',
        delta: '$index',
      ));
    }
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(sessionNotifications, 1);
    expect(session.conversations.single.preview, contains('19'));
    session.dispose();
  });

  test('an unknown turn event refreshes its Provider conversation list', () async {
    late ConversationSummary discovered;
    var listCalls = 0;
    final client = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) async {
        listCalls++;
        if (listCalls == 1) {
          return const ConversationPage(
            conversations: [],
            snapshotCursor: 'handshake',
          );
        }
        return ConversationPage(
          conversations: [discovered],
          snapshotCursor: 'running',
        );
      },
    );
    final session = DeviceSession(
      device: _device('discover-from-turn'),
      clientFactory: () => client,
    );
    await session.connect();
    discovered = _routedConversation(
      nativeId: 'new-thread',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );

    client.emit(TurnUpsertedEvent(
      eventCursor: 'running',
      turn: _turnFor(discovered, TurnStatus.running, 2000),
    ));
    await pumpEventQueue();

    expect(listCalls, 2);
    expect(session.conversations.single.id, discovered.id);
    expect(session.conversations.single.status, ConversationStatus.running);
    session.dispose();
  });

  test('unknown turn events arriving during refresh are drained', () async {
    final firstRefresh = Completer<ConversationPage>();
    final firstRefreshStarted = Completer<void>();
    late ConversationSummary first;
    late ConversationSummary second;
    var listCalls = 0;
    final client = _FakeClient(
      const [],
      onListConversations: ({
        required String route,
        required String? cursor,
        required int limit,
      }) {
        listCalls++;
        if (listCalls == 1) {
          return Future.value(const ConversationPage(
            conversations: [],
            snapshotCursor: 'handshake',
          ));
        }
        if (listCalls == 2) {
          firstRefreshStarted.complete();
          return firstRefresh.future;
        }
        return Future.value(ConversationPage(
          conversations: [second],
          snapshotCursor: 'second-running',
        ));
      },
    );
    final session = DeviceSession(
      device: _device('drain-turn-refresh'),
      clientFactory: () => client,
    );
    await session.connect();
    first = _routedConversation(
      nativeId: 'first-during-refresh',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/repo',
      updatedAt: 1000,
    );
    second = _routedConversation(
      nativeId: 'second-during-refresh',
      providerPluginId: 'dev.codepet.codex',
      providerInstanceId: _primaryRoute,
      workspaceRoot: '/repo',
      updatedAt: 2000,
    );

    client.emit(TurnUpsertedEvent(
      eventCursor: 'first-running',
      turn: _turnFor(first, TurnStatus.running, 3000),
    ));
    await firstRefreshStarted.future;
    client.emit(TurnUpsertedEvent(
      eventCursor: 'second-running',
      turn: _turnFor(second, TurnStatus.running, 4000),
    ));
    firstRefresh.complete(ConversationPage(
      conversations: [first],
      snapshotCursor: 'first-running',
    ));
    await pumpEventQueue(times: 4);

    expect(listCalls, 3);
    expect(
      session.conversations.map((conversation) => conversation.title),
      containsAll(['first-during-refresh', 'second-during-refresh']),
    );
    expect(
      session.conversations.map((conversation) => conversation.status),
      everyElement(ConversationStatus.running),
    );
    session.dispose();
  });

  test('summary events cannot enlarge paginated membership or counts', () async {
    final client = _FakeClient([_conversation('listed', '/one', 1000)]);
    final session = DeviceSession(device: _device('membership'), clientFactory: () => client);
    await session.connect();
    for (var index = 0; index < 300; index++) {
      client.emit(ConversationUpsertedEvent(eventCursor: 'bulk-$index', conversation: _conversation('outside-$index', '/one', 3000)));
    }
    client.emit(ConversationUpsertedEvent(eventCursor: 'known', conversation: _conversation('listed', '/one', 4000)));
    await Future<void>.delayed(Duration.zero);
    expect(session.conversations.map((row) => row.id), ['listed']);
    expect(session.conversations.single.updatedAt.millisecondsSinceEpoch, 4000);
    session.dispose();
  });

  test('sessions isolate projections and disconnect clears runtime data', () async {
    final firstClient = _FakeClient([_conversation('first', '/one', 1000)]);
    final secondClient = _FakeClient([_conversation('second', '/two', 2000)]);
    final first = DeviceSession(device: _device('one'), clientFactory: () => firstClient);
    final second = DeviceSession(device: _device('two'), clientFactory: () => secondClient);
    await Future.wait([first.connect(), second.connect()]);
    expect(first.conversations.single.id, 'first');
    expect(second.conversations.single.id, 'second');
    firstClient.emit(ConversationUpsertedEvent(eventCursor: 'event-2', conversation: _conversation('first-new', '/one', 3000)));
    await Future<void>.delayed(Duration.zero);
    expect(first.conversations.map((item) => item.id), ['first']);
    expect(second.conversations.single.id, 'second');
    await first.disconnect();
    expect(first.conversations, isEmpty);
    expect(first.handshake, isNull);
    expect(second.conversations.single.id, 'second');
    second.dispose();
  });

  test('runtime leases expire when the session reconnects or disconnects', () async {
    final firstClient = _FakeClient(const []);
    final secondClient = _FakeClient(const []);
    final clients = [firstClient, secondClient];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('runtime-lease'),
      clientFactory: () => clients[factoryCalls++],
    );

    await session.connect();
    final firstLease = session.runtimeLease!;
    expect(session.ownsRuntimeLease(firstLease), isTrue);

    await session.connect();
    final secondLease = session.runtimeLease!;
    expect(session.ownsRuntimeLease(firstLease), isFalse);
    expect(session.ownsRuntimeLease(secondLease), isTrue);
    expect(firstLease.sameRuntime(secondLease), isFalse);

    await session.disconnect();
    expect(session.runtimeLease, isNull);
    expect(session.ownsRuntimeLease(secondLease), isFalse);
    session.dispose();
  });

  test('failed connect discards client and retry creates a fresh client', () async {
    final failed = _FailingClient();
    final successful = _FakeClient([_conversation('recovered', '/repo', 1000)]);
    final clients = <GatewayClient>[failed, successful];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('retry'),
      clientFactory: () {
        final client = clients[factoryCalls];
        factoryCalls++;
        return client;
      },
    );

    await session.connect();
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, 'first connection failed');
    expect(session.handshake, isNull);
    expect(session.conversations, isEmpty);
    expect(failed.closeCalled, isTrue);

    await session.connect();
    expect(factoryCalls, 2);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.error, isNull);
    expect(session.conversations.single.id, 'recovered');
    session.dispose();
  });

  test('bounded candidate failure leaves connecting and exposes retry state', () async {
    final client = _ControlledConnectClient();
    final session = DeviceSession(
      device: _device('bounded-connect-failure'),
      clientFactory: () => client,
      autoReconnect: false,
    );

    final attempt = session.connect();
    expect(session.connectionState, DeviceConnectionState.connecting);
    await client.connectStarted.future;
    client.connectResult.completeError(
      const GatewayConnectionException(
        'all Gateway candidates timed out',
        retryable: true,
      ),
    );

    await attempt.timeout(const Duration(seconds: 1));

    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, contains('timed out'));
    expect(client.closeCalled, isTrue);
    session.dispose();
  });

  test('failed connect automatically retries with a fresh client', () async {
    final failed = _FailingClient();
    final successful = _FakeClient([
      _conversation('automatically-recovered', '/repo', 1000),
    ]);
    final clients = <GatewayClient>[failed, successful];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('automatic-retry'),
      clientFactory: () => clients[factoryCalls++],
      reconnectDelays: const [Duration.zero],
    );

    await session.connect();
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(failed.closeCalled, isTrue);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'automatically-recovered');
    session.dispose();
  });

  test('fresh discovery wakes a retryable failed session immediately', () async {
    final discoverySignals = StreamController<void>.broadcast();
    final failed = _FailingClient();
    final successful = _FakeClient([
      _conversation('discovery-recovered', '/repo', 1000),
    ]);
    final clients = <GatewayClient>[failed, successful];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('discovery-retry'),
      clientFactory: () => clients[factoryCalls++],
      reconnectDelays: const [Duration(hours: 1)],
      reconnectSignals: discoverySignals.stream,
    );

    await session.connect();
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(factoryCalls, 1);

    discoverySignals.add(null);
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'discovery-recovered');
    session.dispose();
    await discoverySignals.close();
  });

  test('discovery does not retry a rejected credential', () async {
    final discoverySignals = StreamController<void>.broadcast();
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('discovery-rejected'),
      clientFactory: () {
        factoryCalls++;
        return _NonRetryableClient();
      },
      reconnectSignals: discoverySignals.stream,
    );

    await session.connect();
    discoverySignals.add(null);
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.failed);
    session.dispose();
    await discoverySignals.close();
  });

  test('late failed cleanup cannot schedule over a manual healthy connection', () async {
    final failed = _DelayedCleanupFailingClient();
    final healthy = _FakeClient([
      _conversation('manual-recovery', '/repo', 1000),
    ]);
    final clients = <GatewayClient>[failed, healthy];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('late-failure-manual-recovery'),
      clientFactory: () => clients[factoryCalls++],
      reconnectDelays: const [Duration.zero],
    );

    final failedAttempt = session.connect();
    await failed.closeStarted.future;
    await session.connect();

    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'manual-recovery');

    failed.finishClose();
    await failedAttempt;
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(healthy.closed, isFalse);
    expect(session.connectionState, DeviceConnectionState.online);
    session.dispose();
  });

  test('explicit disconnect cancels a scheduled automatic retry', () async {
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('cancel-automatic-retry'),
      clientFactory: () {
        factoryCalls++;
        return _FailingClient();
      },
      reconnectDelays: const [Duration.zero],
    );

    await session.connect();
    await session.disconnect();
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.offline);
    session.dispose();
  });

  test('disconnect fences a retryable failure still cleaning up', () async {
    final failed = _DelayedCleanupFailingClient();
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('disconnect-during-cleanup'),
      clientFactory: () {
        factoryCalls++;
        return failed;
      },
      reconnectDelays: const [Duration.zero],
    );

    final failedAttempt = session.connect();
    await failed.closeStarted.future;
    await session.disconnect();
    failed.finishClose();
    await failedAttempt;
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.offline);
    session.dispose();
  });

  test('dispose fences a retryable failure still cleaning up', () async {
    final failed = _DelayedCleanupFailingClient();
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('dispose-during-cleanup'),
      clientFactory: () {
        factoryCalls++;
        return failed;
      },
      reconnectDelays: const [Duration.zero],
    );

    final failedAttempt = session.connect();
    await failed.closeStarted.future;
    session.dispose();
    failed.finishClose();
    await failedAttempt;
    await pumpEventQueue();

    expect(factoryCalls, 1);
  });

  test('non-retryable connection failure does not loop in the background', () async {
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('rejected-credential'),
      clientFactory: () {
        factoryCalls++;
        return _NonRetryableClient();
      },
      reconnectDelays: const [Duration.zero],
    );

    await session.connect();
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, 'credential rejected');

    await session.connect();
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(session.connectionState, DeviceConnectionState.failed);
    session.dispose();
  });

  test('reconnect while online closes the old client and creates a new one', () async {
    var firstPageAttempts = 0;
    final first = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) async {
        if (cursor == null) {
          return ConversationPage(
            conversations: [_conversation('old', '/repo', 1000)],
            nextCursor: 'retry-page',
            snapshotCursor: 'handshake',
          );
        }
        firstPageAttempts++;
        throw StateError('old page failure');
      },
    );
    final second = _FakeClient([_conversation('new', '/repo', 2000)]);
    final clients = [first, second];
    var calls = 0;
    final session = DeviceSession(
      device: _device('reconnect'),
      clientFactory: () => clients[calls++],
    );
    await session.connect();
    await session.loadMoreConversations();
    expect(firstPageAttempts, 1);
    expect(session.loadMoreError, isNotNull);
    expect(session.canLoadMoreConversations, isTrue);

    await session.connect();

    expect(calls, 2);
    expect(first.closed, isTrue);
    expect(session.conversations.single.id, 'new');
    expect(session.canLoadMoreConversations, isFalse);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, isNull);
    session.dispose();
  });

  test('disconnect resets pagination and ignores a late page response', () async {
    final nextPage = Completer<ConversationPage>();
    final client = _FakeClient(
      const [],
      onListConversations: ({required String route, required String? cursor, required int limit}) {
        if (cursor == null) {
          return Future.value(
            ConversationPage(
              conversations: [_conversation('first', '/repo', 1000)],
              nextCursor: 'page-2',
              snapshotCursor: 'handshake',
            ),
          );
        }
        return nextPage.future;
      },
    );
    final session = DeviceSession(
      device: _device('disconnect-page'),
      clientFactory: () => client,
    );
    await session.connect();
    final request = session.loadMoreConversations();
    expect(session.isLoadingMoreConversations, isTrue);

    await session.disconnect();

    expect(session.conversations, isEmpty);
    expect(session.canLoadMoreConversations, isFalse);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, isNull);

    nextPage.complete(
      ConversationPage(
        conversations: [_conversation('late', '/repo', 2000)],
        snapshotCursor: 'handshake',
      ),
    );
    await request;

    expect(session.connectionState, DeviceConnectionState.offline);
    expect(session.conversations, isEmpty);
    session.dispose();
  });

  test('event stream failure clears the complete runtime projection', () async {
    final client = _FakeClient(
      [_conversation('stale', '/repo', 1000)],
      nextCursor: 'page-2',
    );
    final session = DeviceSession(device: _device('lost'), clientFactory: () => client);
    await session.connect();
    expect(session.canLoadMoreConversations, isTrue);
    client.controller.addError(StateError('socket lost'));
    await Future<void>.delayed(Duration.zero);
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.handshake, isNull);
    expect(session.conversations, isEmpty);
    expect(session.canLoadMoreConversations, isFalse);
    expect(session.isLoadingMoreConversations, isFalse);
    expect(session.loadMoreError, isNull);
    expect(client.closed, isTrue);
    session.dispose();
  });

  test('event stream failure automatically reconnects with a fresh client', () async {
    final disconnected = _FakeClient([
      _conversation('stale', '/repo', 1000),
    ]);
    final recovered = _FakeClient([
      _conversation('fresh', '/repo', 2000),
    ]);
    final clients = <GatewayClient>[disconnected, recovered];
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('network-recovery'),
      clientFactory: () => clients[factoryCalls++],
      reconnectDelays: const [Duration.zero],
    );
    await session.connect();

    disconnected.controller.addError(const GatewayConnectionException(
      'socket lost',
      retryable: true,
    ));
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(disconnected.closed, isTrue);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'fresh');
    session.dispose();
  });

  test('re-pairing the same device replaces and disposes its old session', () async {
    final oldClient = _FakeClient(const []);
    final replacementClient = _FakeClient(const []);
    final sessions = [DeviceSession(device: _device('same'), clientFactory: () => oldClient)];
    await sessions.single.connect();
    final replacement = DeviceSession(device: _device('same'), clientFactory: () => replacementClient);
    final index = await replaceDeviceSession(sessions, replacement);
    expect(index, 0);
    expect(sessions, [replacement]);
    expect(oldClient.closed, isTrue);
    replacement.dispose();
  });
}

PairedDevice _device(String id) => PairedDevice(deviceId: id, displayName: id, connectionKind: DeviceConnectionKind.demo);

ConversationSummary _conversation(
  String id,
  String? root,
  int milliseconds, {
  String providerId = 'test',
  String? title,
}) => ConversationSummary(
  id: id, providerId: providerId, title: title ?? id, status: ConversationStatus.idle,
  permissionLevel: PermissionLevel.readOnly, workspaceRoot: root,
  createdAt: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
);

ConversationSummary _routedConversation({
  String? domainId,
  required String nativeId,
  required String providerPluginId,
  required String providerInstanceId,
  required String workspaceRoot,
  required int updatedAt,
  String? title,
  RoutedResourceId? project,
}) {
  final resource = RoutedResourceId(
    providerId: providerInstanceId,
    nativeResourceId: nativeId,
  );
  final id = resource.key;
  return ConversationSummary(
    id: domainId ?? id,
    providerId: providerInstanceId,
    title: title ?? nativeId,
    status: ConversationStatus.idle,
    permissionLevel: PermissionLevel.readOnly,
    workspaceRoot: workspaceRoot,
    project: project,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    resource: resource,
  );
}

TurnTask _turnFor(
  ConversationSummary conversation,
  TurnStatus status,
  int updatedAt,
) {
  final conversationResource = conversation.resource!;
  final turnResource = RoutedResourceId(
    providerId: conversationResource.providerId,
    nativeResourceId: 'turn-live',
  );
  return TurnTask(
    id: turnResource.key,
    providerId: conversation.providerId,
    conversationId: conversationRoutingKey(conversation),
    status: status,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAt, isUtc: true),
    resource: turnResource,
    conversationResource: conversationResource,
  );
}

typedef _ListConversationsHandler = Future<ConversationPage> Function({
  required String route,
  required String? cursor,
  required int limit,
});

class _ConversationListRequest {
  const _ConversationListRequest({
    required this.route,
    required this.projectFilter,
    required this.cursor,
    required this.limit,
  });

  final String route;
  final ConversationProjectFilter projectFilter;
  final String? cursor;
  final int limit;
}

class _FakeClient implements GatewayClient, ProviderSnapshotGatewayClient {
  _FakeClient(
    this.values, {
    this.nextCursor,
    this.onListConversations,
    this.onDescribeProvider,
    this.providers = const [_listProvider],
  });
  final List<ConversationSummary> values;
  final String? nextCursor;
  final _ListConversationsHandler? onListConversations;
  final Future<GatewayProvider> Function(String providerId)?
      onDescribeProvider;
  final List<GatewayProvider> providers;
  final StreamController<List<GatewayProvider>> snapshots = StreamController.broadcast();
  @override Stream<List<GatewayProvider>> get providerSnapshots => snapshots.stream;
  final List<String> describeProviderIds = [];
  final List<_ConversationListRequest> listRequests = [];
  final StreamController<GatewayEvent> controller = StreamController<GatewayEvent>.broadcast();
  String _cursor = 'handshake';
  bool closed = false;
  @override Stream<GatewayEvent> get events => controller.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; controller.add(event); }
  @override Future<GatewayHandshake> connect() async => GatewayHandshake(protocolVersion: 1, providers: providers, eventCursor: 'handshake', deviceDescriptor: const DeviceDescriptor(deviceName: 'Test', operatingSystem: 'TestOS', systemVersion: '1'));
  @override Future<GatewayProvider> describeProvider(String providerId) {
    describeProviderIds.add(providerId);
    final handler = onDescribeProvider;
    return handler == null
        ? Future.value(
            providers.singleWhere((provider) => provider.id == providerId),
          )
        : handler(providerId);
  }
  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    listRequests.add(_ConversationListRequest(
      route: providerId,
      projectFilter: projectFilter,
      cursor: cursor,
      limit: limit,
    ));
    final handler = onListConversations;
    if (handler != null) {
      return handler(route: providerId, cursor: cursor, limit: limit);
    }
    return ConversationPage(
      conversations: values,
      nextCursor: nextCursor,
      snapshotCursor: 'handshake',
    );
  }
  @override Future<ConversationPage> searchConversations({required String providerId, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async => ConversationSnapshot(detail: ConversationDetail(summary: conversation), snapshotCursor: _cursor);
  @override Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) async => const ConversationInteraction(selection: TurnSendSelection());
  @override Future<ConversationSummary> createConversation({required String providerId, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw UnimplementedError();
  @override Future<TurnSendReceipt> sendTurn({required String providerId, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw UnimplementedError();
  @override Future<void> close() async { closed = true; await snapshots.close(); await controller.close(); }
}

class _ProjectFakeClient extends _FakeClient implements ProjectGatewayClient {
  _ProjectFakeClient({
    required List<GatewayProject> projects,
    required List<ConversationSummary> conversations,
    List<GatewayProvider> providers = const [_projectProvider],
    Future<GatewayProvider> Function(String providerId)? onDescribeProvider,
  })  : projects = List.of(projects),
        super(conversations, providers: providers, onDescribeProvider: onDescribeProvider);

  final List<GatewayProject> projects;
  int projectListCalls = 0;
  Completer<ProjectPage>? nextProjectPage;

  @override
  Future<ConversationPage> listConversations({
    required String providerId,
    required ConversationProjectFilter projectFilter,
    String? cursor,
    int limit = 50,
  }) async {
    listRequests.add(_ConversationListRequest(
      route: providerId,
      projectFilter: projectFilter,
      cursor: cursor,
      limit: limit,
    ));
    final filtered = values.where((conversation) => switch (projectFilter) {
          AllConversationFilter() => true,
          StandaloneConversationFilter() => conversation.project == null,
          ProjectConversationFilter(:final project) =>
            conversation.project == project,
        });
    return ConversationPage(
      conversations: filtered.take(limit).toList(growable: false),
      snapshotCursor: 'handshake',
    );
  }

  @override
  Future<ProjectPage> listProjects({
    required String providerId,
    String? cursor,
    int limit = 50,
  }) async {
    projectListCalls++;
    final pending = nextProjectPage;
    if (pending != null) {
      nextProjectPage = null;
      return pending.future;
    }
    return ProjectPage(
      projects: projects.take(limit).toList(growable: false),
      snapshotCursor: 'handshake',
    );
  }

  @override
  Future<GatewayProject> getProject(RoutedResourceId project) async =>
      projects.firstWhere((candidate) => candidate.resource == project);

  @override
  Future<GatewayProject> createProject({
    required String providerId,
    required String idempotencyKey,
    required String name,
    required List<ProjectRoot> roots,
    Map<String, String> metadata = const {},
  }) async {
    final now = DateTime.now().toUtc();
    final project = GatewayProject(
      resource: RoutedResourceId(
        providerId: providerId,
        nativeResourceId: 'created-${projects.length}',
      ),
      name: name,
      roots: roots,
      metadata: metadata,
      position: projects.length,
      createdAt: now,
      updatedAt: now,
    );
    projects.add(project);
    return project;
  }

  @override
  Future<GatewayProject> updateProject({
    required RoutedResourceId project,
    String? name,
    List<ProjectRoot>? roots,
    Map<String, String>? metadata,
  }) async {
    final index = projects.indexWhere((item) => item.resource == project);
    final current = projects[index];
    final updated = GatewayProject(
      resource: project,
      name: name ?? current.name,
      roots: roots ?? current.roots,
      metadata: metadata ?? current.metadata,
      position: current.position,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt.add(const Duration(seconds: 1)),
    );
    projects[index] = updated;
    return updated;
  }

  @override
  Future<void> deleteProject(RoutedResourceId project) async {
    projects.removeWhere((item) => item.resource == project);
  }
}

class _FailingClient implements GatewayClient {
  bool closeCalled = false;
  @override Stream<GatewayEvent> get events => const Stream.empty();
  @override String? get latestEventCursor => null;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(null, events);
  @override Future<GatewayHandshake> connect() => Future.error(
    const GatewayConnectionException(
      'first connection failed',
      retryable: true,
    ),
  );
  @override Future<GatewayProvider> describeProvider(String providerId) => throw StateError('not reached');
  @override Future<ConversationPage> listConversations({required String providerId, required ConversationProjectFilter projectFilter, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationPage> searchConversations({required String providerId, required String searchTerm, String? cursor, int limit = 50}) => throw StateError('not reached');
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<ConversationInteraction> acquireInteraction(ConversationSummary conversation) => throw StateError('not reached');
  @override Future<ConversationSummary> createConversation({required String providerId, String? title, required String permissionLevel, String? model, String? reasoningEffort, String? workspaceRoot, String? workspaceMode, RoutedResourceId? project}) => throw StateError('not reached');
  @override Future<TurnSendReceipt> sendTurn({required String providerId, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) => throw StateError('not reached');
  @override Future<void> close() async {
    closeCalled = true;
    throw StateError('close also failed');
  }
}

class _ControlledConnectClient extends _FailingClient {
  final Completer<void> connectStarted = Completer<void>();
  final Completer<GatewayHandshake> connectResult =
      Completer<GatewayHandshake>();

  @override
  Future<GatewayHandshake> connect() {
    if (!connectStarted.isCompleted) connectStarted.complete();
    return connectResult.future;
  }
}

const _primaryRoute = 'codex-work';

const _listProvider = GatewayProvider(
  id: _primaryRoute,
  displayName: 'Codex Work',
  status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.get'],
  ),
);

const _projectProvider = GatewayProvider(
  id: _primaryRoute,
  displayName: 'Codex Projects',
  status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'projects-1',
    methods: [
      'project.list',
      'project.get',
      'project.create',
      'project.update',
      'project.delete',
      'conversation.list',
      'conversation.create',
    ],
  ),
);

GatewayProject _gatewayProject() => GatewayProject(
      resource: const RoutedResourceId(
        providerId: _primaryRoute,
        nativeResourceId: 'project-1',
      ),
      name: 'Project One',
      roots: const [ProjectRoot(path: '/same/cwd')],
      metadata: const {},
      position: 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );

const _secondaryRoute = 'claude-work';

const _secondaryListProvider = GatewayProvider(
  id: _secondaryRoute,
  displayName: 'Claude Work',
  status: ProviderStatus.ready,
  capabilities: GatewayCapabilities(
    revision: 'test-1',
    methods: ['conversation.list', 'conversation.get'],
  ),
);

class _NonRetryableClient extends _FailingClient {
  @override
  Future<GatewayHandshake> connect() => Future.error(
    const GatewayConnectionException('credential rejected'),
  );
}

class _DelayedCleanupFailingClient extends _FailingClient {
  final Completer<void> closeStarted = Completer<void>();
  final Completer<void> _finishClose = Completer<void>();

  void finishClose() {
    if (!_finishClose.isCompleted) _finishClose.complete();
  }

  @override
  Future<void> close() async {
    closeCalled = true;
    if (!closeStarted.isCompleted) closeStarted.complete();
    await _finishClose.future;
  }
}
