part of 'device_session_test.dart';

void _connectionLifecycleTests() {
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
    await pumpEventQueue();

    expect(factoryCalls, 2);
    expect(failed.closeCalled, isTrue);
    expect(session.connectionState, DeviceConnectionState.online);
    expect(session.conversations.single.id, 'automatically-recovered');
    session.dispose();
  });

  test('automatic reconnect stops after five retries and manual connect resets it', () async {
    final discoverySignals = StreamController<void>.broadcast();
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('limited-retry'),
      clientFactory: () {
        factoryCalls++;
        return _FailingClient();
      },
      reconnectDelays: const [Duration.zero],
      reconnectSignals: discoverySignals.stream,
    );
    addTearDown(session.dispose);
    addTearDown(discoverySignals.close);

    await session.connect();
    await pumpEventQueue();
    await pumpEventQueue(times: 100);
    expect(factoryCalls, 6); // Initial connection plus five automatic retries.
    expect(session.connectionState, DeviceConnectionState.failed);

    discoverySignals.add(null);
    await pumpEventQueue();
    expect(factoryCalls, 6);

    await session.connect();
    await pumpEventQueue();
    await pumpEventQueue(times: 100);
    expect(factoryCalls, 12);
  });

  test('discovery retries share the five retry limit', () async {
    final discoverySignals = StreamController<void>.broadcast();
    var factoryCalls = 0;
    final session = DeviceSession(
      device: _device('limited-discovery-retry'),
      clientFactory: () {
        factoryCalls++;
        return _FailingClient();
      },
      reconnectDelays: const [Duration(hours: 1)],
      reconnectSignals: discoverySignals.stream,
    );
    addTearDown(session.dispose);
    addTearDown(discoverySignals.close);

    await session.connect();
    await pumpEventQueue();
    for (var attempt = 0; attempt < 7; attempt++) {
      discoverySignals.add(null);
      await pumpEventQueue();
      expect(factoryCalls, attempt < 5 ? attempt + 2 : 6);
    }
    expect(session.connectionState, DeviceConnectionState.failed);
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
    await pumpEventQueue();
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
    await pumpEventQueue();
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
    await pumpEventQueue();

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
    await pumpEventQueue();

    expect(factoryCalls, 1);
    expect(session.connectionState, DeviceConnectionState.failed);
    expect(session.error, 'credential rejected');

    await session.connect();
    await pumpEventQueue();
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
    await pumpEventQueue();
    await session.loadMoreConversations();
    expect(firstPageAttempts, 1);
    expect(session.loadMoreError, isNotNull);
    expect(session.canLoadMoreConversations, isTrue);

    await session.connect();
    await pumpEventQueue();

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
    await pumpEventQueue();
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
    await pumpEventQueue();
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
    await pumpEventQueue();

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
