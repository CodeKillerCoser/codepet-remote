import 'dart:async';

import 'package:codepet_remote/devices/device_models.dart';
import 'package:codepet_remote/devices/device_session.dart';
import 'package:codepet_remote/features/conversations/conversation_detail_screen.dart';
import 'package:codepet_remote/gateway/gateway_client.dart';
import 'package:codepet_remote/gateway/models.dart';
import 'package:codepet_remote/gateway/transport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the latest history page and reveals earlier messages', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        for (var index = 0; index < 45; index++)
          _history(
            'history-$index',
            MessageRole.user,
            'message',
            '历史消息 $index',
            createdMilliseconds: index,
          ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('message-history-0')), findsNothing);
    expect(find.byKey(const Key('message-history-44')), findsOneWidget);

    final position = _detailScrollPosition(tester);
    position.jumpTo(0);
    await tester.pump();
    expect(find.byKey(const Key('show-earlier-messages')), findsOneWidget);
    await tester.tap(find.byKey(const Key('show-earlier-messages')));
    await tester.pump();
    await tester.pump();

    position.jumpTo(0);
    await tester.pump();
    expect(find.byKey(const Key('show-earlier-messages')), findsNothing);
    expect(find.byKey(const Key('message-history-0')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('message-history-0'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('message-history-1'))).dy,
      ),
    );

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('keeps committed history in source order', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history(
          'source-first',
          MessageRole.user,
          'message',
          '输入中的第一条',
          createdMilliseconds: 2000,
        ),
        _history(
          'source-second',
          MessageRole.assistant,
          'message',
          '输入中的第二条',
          createdMilliseconds: 1000,
        ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.byKey(const Key('message-source-first'))).dy,
      lessThan(
        tester.getTopLeft(find.byKey(const Key('message-source-second'))).dy,
      ),
    );

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('collapses history and accumulates new output while collapsed', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history('one', MessageRole.user, 'message', '第一条'),
        _history('two', MessageRole.assistant, 'message', '第二条'),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('messages-section-toggle')));
    await tester.pump();
    expect(find.byKey(const Key('message-one')), findsNothing);
    expect(find.byKey(const Key('message-two')), findsNothing);

    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'collapsed-live',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'collapsed-turn',
      itemId: 'collapsed-item',
      contentId: 'collapsed-item:text',
      kind: 'text',
      delta: '折叠期间的新消息',
    ));
    await tester.pump();
    expect(find.text('折叠期间的新消息'), findsNothing);

    await tester.tap(find.byKey(const Key('messages-section-toggle')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('第一条'), findsOneWidget);
    expect(find.text('第二条'), findsOneWidget);
    expect(find.text('折叠期间的新消息'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('shows a scroll-to-bottom button and scrolls on tap', (tester) async {
    final client = _DetailClient(
      committedMessages: _longHistory(),
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    final position = _detailScrollPosition(tester);
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    position.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('scroll-to-bottom')), findsOneWidget);

    await tester.tap(find.byKey(const Key('scroll-to-bottom')));
    await tester.pumpAndSettle();
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(find.byKey(const Key('scroll-to-bottom')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('follows live output near bottom but preserves far scroll position', (tester) async {
    final client = _DetailClient(
      committedMessages: _longHistory(),
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    final position = _detailScrollPosition(tester);
    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'near-live',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'near-turn',
      itemId: 'near-item',
      contentId: 'near-item:text',
      kind: 'text',
      delta: '近底部实时消息',
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(position.pixels, closeTo(position.maxScrollExtent, 1));
    expect(find.text('近底部实时消息'), findsOneWidget);

    position.jumpTo(0);
    await tester.pump();
    final farOffset = position.pixels;
    client.emit(const TurnOutputDeltaEvent(
      eventCursor: 'far-live',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: 'far-turn',
      itemId: 'far-item',
      contentId: 'far-item:text',
      kind: 'text',
      delta: '远离底部实时消息',
    ));
    await tester.pump();
    await tester.pump();
    expect(position.pixels, closeTo(farOffset, 1));
    expect(position.extentAfter, greaterThan(160));

    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('terminal turn refresh clears only its in-memory live output', (tester) async {
    final client = _DetailClient();
    await _pumpDetail(tester, client);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', itemId: 'item', contentId: 'item:text', kind: 'text', delta: 'live-only'));
    await tester.pump();
    expect(find.text('live-only'), findsOneWidget);

    client.emit(TurnUpsertedEvent(eventCursor: 'terminal', turn: TurnTask(id: 'turn', providerId: 'provider', conversationId: 'conversation', status: TurnStatus.completed, updatedAt: DateTime.fromMillisecondsSinceEpoch(1, isUtc: true))));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(client.getCalls, 2);
    expect(find.text('live-only'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('event stream failure discards stale detail and live output', (tester) async {
    final client = _DetailClient();
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();
    client.emit(const TurnOutputDeltaEvent(eventCursor: 'delta', providerId: 'provider', conversationId: 'conversation', turnId: 'turn', itemId: 'item', contentId: 'item:text', kind: 'text', delta: 'stale-live'));
    await tester.pump();
    client.eventsController.addError(StateError('socket lost'));
    await tester.pump();
    expect(find.text('stale-live'), findsNothing);
    expect(find.textContaining('socket lost'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('renders committed messages, tool activity and approval status', (tester) async {
    final client = _DetailClient(
      committedMessages: [
        _history('user', MessageRole.user, 'message', 'Show the history.'),
        _history('assistant', MessageRole.assistant, 'message', 'History is ready.'),
        _history(
          'command',
          MessageRole.system,
          'command',
          'git status --short',
          title: 'Run git status --short',
          status: 'completed',
        ),
        _history(
          'approval',
          MessageRole.system,
          'approval',
          'Run git status --short',
          title: 'Approve command',
          status: 'approved',
          approvalStatus: 'approved',
        ),
      ],
    );
    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(find.text('Show the history.'), findsOneWidget);
    expect(find.text('History is ready.'), findsOneWidget);
    expect(find.text('Run git status --short'), findsWidgets);
    expect(find.text('Approve command'), findsOneWidget);
    expect(find.text('已批准'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('does not duplicate a committed body when its delta replays after the snapshot', (tester) async {
    final committed = GatewayMessage(
      id: 'item',
      itemId: 'item',
      turnId: 'turn',
      role: MessageRole.assistant,
      kind: 'message',
      content: 'committed body',
      contentIds: const ['item:text'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      isStreaming: false,
    );
    final client = _DetailClient(
      committedMessages: [committed],
      eventDuringFirstGet: const TurnOutputDeltaEvent(
        eventCursor: 'after-snapshot',
        providerId: 'provider',
        conversationId: 'conversation',
        turnId: 'turn',
        itemId: 'item',
        contentId: 'item:text',
        kind: 'text',
        delta: 'committed body',
      ),
    );

    await _pumpDetail(tester, client);
    await tester.pumpAndSettle();

    expect(find.text('committed body'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('lays out composer toolbar and sends Provider defaults with original text', (tester) async {
    final provider = _providerWith(
      revision: 'revision-layout',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [
            ProviderChoice(id: 'read', displayName: 'Read only'),
            ProviderChoice(id: 'write', displayName: 'Workspace write'),
          ],
          defaultId: 'write',
        ),
        reasoningEffort: ProviderChoiceSet(
          options: [ProviderChoice(id: 'high', displayName: 'High')],
          defaultId: 'high',
        ),
        modelCatalog: FlatModelCatalog(
          models: [
            ProviderChoice(id: 'fast', displayName: 'Fast'),
            ProviderChoice(id: 'deep', displayName: 'Deep'),
          ],
          defaultSelection: FlatModelSelection(modelId: 'fast'),
        ),
      ),
    );
    final conversation = _idleConversation(
      selection: const TurnSendSelection(
        accessModeId: 'read',
        model: FlatModelSelection(modelId: 'deep'),
      ),
    );
    final client = _DetailClient(provider: provider);
    await _pumpDetail(tester, client, conversation: conversation);
    await tester.pumpAndSettle();

    final inputBottom = tester.getBottomLeft(find.byKey(const Key('turn-input'))).dy;
    final toolbarTop = tester.getTopLeft(find.byKey(const Key('composer-toolbar'))).dy;
    expect(inputBottom, lessThanOrEqualTo(toolbarTop));
    expect(
      tester.getCenter(find.byKey(const Key('access-mode-selector'))).dx,
      lessThan(tester.getCenter(find.byKey(const Key('reasoning-effort-selector'))).dx),
    );
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Deep'), findsOneWidget);
    final reasoningPopup = tester.widget<PopupMenuButton<String>>(
      find.descendant(
        of: find.byKey(const Key('reasoning-effort-selector')),
        matching: find.byType(PopupMenuButton<String>),
      ),
    );
    expect(reasoningPopup.enabled, isFalse);

    await tester.enterText(find.byKey(const Key('turn-input')), '  original text\n');
    await tester.pump();
    final sendButton = tester.widget<IconButton>(
      find.byKey(const Key('turn-send')),
    );
    expect(
      sendButton.onPressed,
      isNotNull,
      reason: tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .decoration
          ?.hintText,
    );
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();

    expect(client.sendCalls, hasLength(1));
    expect(client.sendCalls.single.text, '  original text\n');
    expect(client.sendCalls.single.capabilityRevision, 'revision-layout');
    expect(client.sendCalls.single.selection.accessModeId, 'read');
    expect(client.sendCalls.single.selection.reasoningEffortId, 'high');
    expect(client.sendCalls.single.selection.model?.toJson(), {
      'kind': 'flat',
      'modelId': 'deep',
    });
    expect(find.byKey(const Key('turn-input')), findsOneWidget);
    expect(find.text('original text'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('disables empty, unavailable, active-turn and offline sends while retaining draft', (tester) async {
    final unavailableProvider = _providerWith(
      revision: 'revision-unavailable',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [
            ProviderChoice(
              id: 'disabled',
              displayName: 'Unavailable mode',
              enabled: false,
              disabledReason: 'Disabled by Provider',
            ),
          ],
        ),
      ),
    );
    final unavailableClient = _DetailClient(provider: unavailableProvider);
    final unavailableSession = await _pumpDetail(
      tester,
      unavailableClient,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('turn-input')), 'cannot send');
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );

    await tester.pumpWidget(const SizedBox());
    unawaited(unavailableSession.disconnect());

    final activeTurn = TurnTask(
      id: 'active',
      providerId: 'provider',
      conversationId: 'conversation',
      status: TurnStatus.running,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );
    final activeClient = _DetailClient();
    final activeSession = await _pumpDetail(
      tester,
      activeClient,
      conversation: _idleConversation(activeTurn: activeTurn),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
    unawaited(activeSession.disconnect());

    final offlineClient = _DetailClient();
    final session = await _pumpDetail(
      tester,
      offlineClient,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'saved offline');
    await tester.pump();
    unawaited(session.disconnect());
    await tester.pump();
    expect(find.text('saved offline'), findsOneWidget);
    expect(find.text('设备已离线'), findsOneWidget);
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('uses a new request id after an explicit failure', (tester) async {
    var attempt = 0;
    final client = _DetailClient(onSend: (call) {
      attempt++;
      if (attempt == 1) {
        return Future.error(const GatewayProtocolException(
          code: 'invalid_input',
          message: 'Rejected',
          retryable: false,
        ));
      }
      return Future.value(_receipt(call));
    });
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'retry me');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    final firstId = client.sendCalls.single.clientRequestId;
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    expect(client.sendCalls, hasLength(2));
    expect(client.sendCalls.last.clientRequestId, isNot(firstId));
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('converges send through delta and terminal snapshot', (tester) async {
    final committed = <GatewayMessage>[];
    late TurnSendReceipt accepted;
    final client = _DetailClient(
      committedMessages: committed,
      onSend: (call) {
        accepted = _receipt(call);
        committed.add(accepted.inputItem);
        return Future.value(accepted);
      },
    );
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'start flow');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    client.emit(TurnOutputDeltaEvent(
      eventCursor: 'sent-delta',
      providerId: 'provider',
      conversationId: 'conversation',
      turnId: accepted.turn.id,
      itemId: 'answer',
      contentId: 'answer:text',
      kind: 'text',
      delta: 'streaming answer',
    ));
    await tester.pump();
    expect(find.text('streaming answer'), findsOneWidget);
    committed.add(GatewayMessage(
      id: 'answer',
      itemId: 'answer',
      turnId: accepted.turn.id,
      role: MessageRole.assistant,
      kind: 'message',
      content: 'committed answer',
      contentIds: const ['answer:text'],
      createdAt: DateTime.fromMillisecondsSinceEpoch(6000, isUtc: true),
      isStreaming: false,
    ));
    client.emit(TurnUpsertedEvent(
      eventCursor: 'sent-terminal',
      turn: TurnTask(
        id: accepted.turn.id,
        providerId: 'provider',
        conversationId: 'conversation',
        status: TurnStatus.completed,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(6000, isUtc: true),
        completedAt: DateTime.fromMillisecondsSinceEpoch(6000, isUtc: true),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('streaming answer'), findsNothing);
    expect(find.text('committed answer'), findsOneWidget);
    expect(client.getCalls, 2);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('groups models in the menu and returns provider plus model identity', (tester) async {
    final provider = _providerWith(
      revision: 'revision-grouped',
      turnSend: const TurnSendCapabilities(
        modelCatalog: GroupedModelCatalog(
          providers: [
            ModelProviderGroup(
              id: 'provider-a',
              displayName: 'Provider A',
              models: [ProviderChoice(id: 'shared', displayName: 'Model A')],
            ),
            ModelProviderGroup(
              id: 'provider-b',
              displayName: 'Provider B',
              models: [ProviderChoice(id: 'shared', displayName: 'Model B')],
            ),
          ],
          defaultSelection: GroupedModelSelection(
            providerId: 'provider-a',
            modelId: 'shared',
          ),
        ),
      ),
    );
    final client = _DetailClient(provider: provider);
    await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('model-selector')));
    await tester.pumpAndSettle();
    expect(find.text('Provider A'), findsOneWidget);
    expect(find.text('Provider B'), findsOneWidget);
    await tester.tap(find.text('Model B'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'grouped');
    await tester.pump();
    expect(
      tester.widget<IconButton>(find.byKey(const Key('turn-send'))).onPressed,
      isNotNull,
      reason: tester
          .widget<TextField>(find.byKey(const Key('turn-input')))
          .decoration
          ?.hintText,
    );
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();

    expect(client.sendCalls.single.selection.model?.toJson(), {
      'kind': 'grouped',
      'providerId': 'provider-b',
      'modelId': 'shared',
    });
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('prevents duplicate taps and reuses the request id after an unknown result', (tester) async {
    var attempts = 0;
    final firstPending = Completer<TurnSendReceipt>();
    late _SendCall secondCall;
    final client = _DetailClient(onSend: (call) {
      attempts++;
      if (attempts == 1) return firstPending.future;
      secondCall = call;
      return Future.value(_receipt(call));
    });
    await _pumpDetail(tester, client, conversation: _idleConversation());
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'pending');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    expect(client.sendCalls, hasLength(1));
    final firstId = client.sendCalls.single.clientRequestId;

    firstPending.completeError(
      const GatewayConnectionException('timeout', retryable: true),
    );
    await tester.pump();
    expect(find.byKey(const Key('turn-send-error')), findsOneWidget);
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();
    expect(client.sendCalls, hasLength(2));
    expect(secondCall.clientRequestId, firstId);
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });

  testWidgets('revision change preserves draft and ignores the old send callback', (tester) async {
    final pending = Completer<TurnSendReceipt>();
    final firstProvider = _providerWith(
      revision: 'revision-old',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [ProviderChoice(id: 'old', displayName: 'Old mode')],
          defaultId: 'old',
        ),
      ),
    );
    final client = _DetailClient(
      provider: firstProvider,
      onSend: (_) => pending.future,
    );
    final session = await _pumpDetail(
      tester,
      client,
      conversation: _idleConversation(),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('turn-input')), 'keep this draft');
    await tester.pump();
    await tester.tap(find.byKey(const Key('turn-send')));
    await tester.pump();

    final nextProvider = _providerWith(
      revision: 'revision-new',
      turnSend: const TurnSendCapabilities(
        accessMode: ProviderChoiceSet(
          options: [ProviderChoice(id: 'new', displayName: 'New mode')],
          defaultId: 'new',
        ),
      ),
    );
    client.emit(GatewayProviderChangedEvent(
      eventCursor: 'provider-new',
      provider: nextProvider,
    ));
    expect(
      session.handshake?.providers.single.capabilities.revision,
      'revision-new',
    );
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    final accessLabels = tester
        .widgetList<Text>(find.descendant(
          of: find.byKey(const Key('access-mode-selector')),
          matching: find.byType(Text),
        ))
        .map((text) => text.data)
        .toList();
    expect(accessLabels, contains('New mode'));
    expect(find.text('keep this draft'), findsOneWidget);

    pending.complete(_receipt(client.sendCalls.single));
    await tester.pump();
    expect(find.text('keep this draft'), findsOneWidget);
    expect(client.sendCalls, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    await client.close();
  });
}

Future<DeviceSession> _pumpDetail(
  WidgetTester tester,
  _DetailClient client, {
  ConversationSummary? conversation,
}) async {
  final session = DeviceSession(
    device: const PairedDevice(
      deviceId: 'host',
      displayName: 'Host',
      connectionKind: DeviceConnectionKind.demo,
    ),
    clientFactory: () => client,
    autoReconnect: false,
  );
  await session.connect();
  addTearDown(session.dispose);
  await tester.pumpWidget(MaterialApp(
    home: ConversationDetailScreen(
      session: session,
      conversation: conversation ?? _conversation,
    ),
  ));
  return session;
}

GatewayMessage _history(
  String id,
  MessageRole role,
  String kind,
  String content, {
  String? title,
  String? status,
  String? approvalStatus,
  int createdMilliseconds = 0,
}) =>
    GatewayMessage(
      id: id,
      turnId: 'turn',
      role: role,
      kind: kind,
      content: content,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        createdMilliseconds,
        isUtc: true,
      ),
      isStreaming: false,
      title: title,
      status: status,
      approvalStatus: approvalStatus,
    );

List<GatewayMessage> _longHistory() => [
  for (var index = 0; index < 60; index++)
    _history(
      'long-$index',
      index.isEven ? MessageRole.user : MessageRole.assistant,
      'message',
      '长历史 $index ${List.filled(20, '内容 ').join()}',
      createdMilliseconds: index,
    ),
];

ScrollPosition _detailScrollPosition(WidgetTester tester) {
  final scrollable = find.descendant(
    of: find.byKey(const Key('conversation-detail')),
    matching: find.byType(Scrollable),
  );
  return tester.state<ScrollableState>(scrollable).position;
}

final _conversation = ConversationSummary(
  id: 'conversation',
  providerId: 'provider',
  title: 'Conversation',
  status: ConversationStatus.running,
  permissionLevel: PermissionLevel.readOnly,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  wireResource: const {
    'deviceId': 'host',
    'providerPluginId': 'plugin',
    'providerInstanceId': 'provider',
    'nativeResourceId': 'conversation',
  },
);

const _detailRoute = GatewayProviderRoute(
  deviceId: 'host',
  providerPluginId: 'plugin',
  providerInstanceId: 'provider',
);

const _detailProvider = GatewayProvider(
  route: _detailRoute,
  providerType: 'plugin',
  displayName: 'Provider',
  status: ProviderStatus.ready,
  harness: HarnessDescriptor(id: 'test', displayName: 'Test Harness'),
  capabilities: GatewayCapabilities(
    revision: 'revision-1',
    methods: ['conversation.get', 'turn.send'],
    turnSend: TurnSendCapabilities(),
  ),
);

GatewayProvider _providerWith({
  required String revision,
  required TurnSendCapabilities turnSend,
}) =>
    GatewayProvider(
      route: _detailRoute,
      providerType: 'plugin',
      displayName: 'Provider',
      status: ProviderStatus.ready,
      harness: const HarnessDescriptor(
        id: 'test',
        displayName: 'Test Harness',
      ),
      capabilities: GatewayCapabilities(
        revision: revision,
        methods: const ['conversation.get', 'turn.send'],
        turnSend: turnSend,
      ),
    );

ConversationSummary _idleConversation({
  TurnSendSelection? selection,
  TurnTask? activeTurn,
}) =>
    ConversationSummary(
      id: _conversation.id,
      providerId: _conversation.providerId,
      title: _conversation.title,
      status: ConversationStatus.idle,
      permissionLevel: _conversation.permissionLevel,
      createdAt: _conversation.createdAt,
      updatedAt: _conversation.updatedAt,
      activeTurn: activeTurn,
      turnSendSelection: selection,
      wireResource: _conversation.wireResource,
    );

class _DetailClient implements GatewayClient {
  _DetailClient({
    this.committedMessages = const [],
    this.eventDuringFirstGet,
    this.provider = _detailProvider,
    this.onSend,
  });

  final List<GatewayMessage> committedMessages;
  final GatewayEvent? eventDuringFirstGet;
  GatewayProvider provider;
  final Future<TurnSendReceipt> Function(_SendCall call)? onSend;
  final StreamController<GatewayEvent> eventsController = StreamController<GatewayEvent>.broadcast(sync: true);
  final List<_SendCall> sendCalls = [];
  String _cursor = 'H';
  int getCalls = 0;

  @override Stream<GatewayEvent> get events => eventsController.stream;
  @override String? get latestEventCursor => _cursor;
  @override GatewayEventWindow openEventWindow() => GatewayEventWindow.forStream(_cursor, events);
  void emit(GatewayEvent event) { _cursor = event.eventCursor; eventsController.add(event); }
  @override Future<ConversationSnapshot> getConversation(ConversationSummary conversation) async {
    getCalls++;
    final snapshotCursor = _cursor;
    if (getCalls == 1 && eventDuringFirstGet != null) {
      emit(eventDuringFirstGet!);
    }
    return ConversationSnapshot(detail: ConversationDetail(summary: conversation, committedMessages: committedMessages), snapshotCursor: snapshotCursor);
  }
  @override Future<GatewayHandshake> connect() async => GatewayHandshake(protocolVersion: 1, serverName: 'Test', serverVersion: '1', providers: [provider], eventCursor: _cursor);
  @override Future<ConversationPage> listConversations({required GatewayProviderRoute route, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override Future<ConversationPage> searchConversations({required GatewayProviderRoute route, required String searchTerm, String? cursor, int limit = 50}) => throw UnimplementedError();
  @override
  Future<TurnSendReceipt> sendTurn({required GatewayProviderRoute route, required ConversationSummary conversation, required String clientRequestId, required String capabilityRevision, required String text, required TurnSendSelection selection}) {
    final call = _SendCall(
      route: route,
      conversation: conversation,
      clientRequestId: clientRequestId,
      capabilityRevision: capabilityRevision,
      text: text,
      selection: selection,
    );
    sendCalls.add(call);
    final handler = onSend;
    return handler == null ? Future.value(_receipt(call)) : handler(call);
  }
  @override Future<void> close() async {}
}

class _SendCall {
  const _SendCall({
    required this.route,
    required this.conversation,
    required this.clientRequestId,
    required this.capabilityRevision,
    required this.text,
    required this.selection,
  });

  final GatewayProviderRoute route;
  final ConversationSummary conversation;
  final String clientRequestId;
  final String capabilityRevision;
  final String text;
  final TurnSendSelection selection;
}

TurnSendReceipt _receipt(_SendCall call) {
  final now = DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true);
  return TurnSendReceipt(
    clientRequestId: call.clientRequestId,
    turn: TurnTask(
      id: 'turn-${call.clientRequestId}',
      providerId: call.conversation.providerId,
      conversationId: call.conversation.id,
      status: TurnStatus.queued,
      updatedAt: now,
    ),
    inputItem: GatewayMessage(
      id: 'item-${call.clientRequestId}',
      turnId: 'turn-${call.clientRequestId}',
      role: MessageRole.user,
      kind: 'message',
      content: call.text,
      createdAt: now,
      isStreaming: false,
    ),
    effectiveSelection: call.selection,
  );
}
