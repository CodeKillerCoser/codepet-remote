import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device descriptor encodes and decodes the Gateway shape', () {
    const descriptor = DeviceDescriptor(
      deviceName: 'Alice phone',
      operatingSystem: 'Android',
      systemVersion: '16',
    );

    final decoded = DeviceDescriptor.fromJson(descriptor.toJson());

    expect(decoded.deviceName, descriptor.deviceName);
    expect(decoded.operatingSystem, descriptor.operatingSystem);
    expect(decoded.systemVersion, descriptor.systemVersion);
    expect(
      () => DeviceDescriptor.fromJson({
        'deviceName': 'Alice phone',
        'operatingSystem': 'Android',
      }),
      throwsFormatException,
    );
  });

  group('Provider turn.send capabilities', () {
    test('decodes flat catalog display metadata and default selection', () {
      final catalog = ModelCatalog.fromJson({
        'kind': 'flat',
        'models': [
          {
            'id': 'fast',
            'displayName': 'Fast model',
            'description': 'Low latency',
          },
          {
            'id': 'retired',
            'displayName': 'Retired model',
            'enabled': false,
            'disabledReason': 'No longer available',
          },
        ],
        'defaultSelection': {'kind': 'flat', 'modelId': 'fast'},
      }) as FlatModelCatalog;

      expect(catalog.models.first.displayName, 'Fast model');
      expect(catalog.models.first.description, 'Low latency');
      expect(catalog.availableSelections, [
        const FlatModelSelection(modelId: 'fast'),
      ]);
      expect(catalog.defaultSelection?.toJson(), {
        'kind': 'flat',
        'modelId': 'fast',
      });
    });

    test('decodes grouped catalog without treating inner provider as route', () {
      final catalog = ModelCatalog.fromJson({
        'kind': 'grouped',
        'providers': [
          {
            'id': 'inference-a',
            'displayName': 'Inference A',
            'description': 'First model provider',
            'models': [
              {'id': 'shared', 'displayName': 'Shared A'},
            ],
          },
          {
            'id': 'inference-b',
            'displayName': 'Inference B',
            'models': [
              {'id': 'shared', 'displayName': 'Shared B'},
            ],
          },
        ],
        'defaultSelection': {
          'kind': 'grouped',
          'providerId': 'inference-b',
          'modelId': 'shared',
        },
      }) as GroupedModelCatalog;

      expect(catalog.providers.map((item) => item.displayName), [
        'Inference A',
        'Inference B',
      ]);
      expect(catalog.availableSelections, [
        const GroupedModelSelection(
          providerId: 'inference-a',
          modelId: 'shared',
        ),
        const GroupedModelSelection(
          providerId: 'inference-b',
          modelId: 'shared',
        ),
      ]);
      expect(catalog.defaultSelection?.toJson(), {
        'kind': 'grouped',
        'providerId': 'inference-b',
        'modelId': 'shared',
      });
    });

    test('rejects malformed kinds, empty controls and invalid defaults', () {
      expect(
        () => ModelCatalog.fromJson({
          'models': [
            {'id': 'model', 'displayName': 'Model'},
          ],
        }),
        throwsFormatException,
      );
      expect(
        () => ModelCatalog.fromJson({
          'kind': 'flat',
          'models': <Object>[],
        }),
        throwsFormatException,
      );
      expect(
        () => ProviderChoiceSet.fromJson({
          'options': [
            {
              'id': 'disabled',
              'displayName': 'Disabled',
              'enabled': false,
            },
          ],
          'defaultId': 'disabled',
        }),
        throwsFormatException,
      );
    });
  });

  group('ConversationDetail event projection', () {
    final summary = ConversationSummary(
      id: 'conversation-1',
      providerId: 'codex',
      title: 'Test conversation',
      preview: 'Preview',
      status: ConversationStatus.running,
      permissionLevel: PermissionLevel.workspaceWrite,
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(2000, isUtc: true),
    );

    test('merges output deltas by routed content id', () {
      var detail = ConversationDetail(summary: summary);

      detail = detail.apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-8',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          itemId: 'item-1',
          contentId: 'item-1:text',
          kind: 'text',
          delta: 'hello ',
        ),
      );
      detail = detail.apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-9',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          itemId: 'item-1',
          contentId: 'item-1:text',
          kind: 'text',
          delta: 'world',
        ),
      );

      expect(detail.messages, hasLength(1));
      expect(detail.messages.single.content, 'hello world');
      expect(detail.messages.single.isStreaming, isTrue);
      expect(detail.lastEventCursor, 'event-9');
    });

    test('retained output stays before the next request and canonical replacements keep their position', () {
      var detail = ConversationDetail(summary: summary).apply(const TurnOutputDeltaEvent(
        eventCursor: 'output', providerId: 'codex', conversationId: 'conversation-1',
        turnId: 'turn-1', itemId: 'answer', contentId: 'answer:text', kind: 'text', delta: 'first answer'));
      detail = detail.stageUserInput(clientRequestId: 'next', text: 'next question', createdAt: DateTime(2026));
      expect(detail.messages.map((m) => m.content), ['first answer', 'next question']);
      detail = detail.apply(ConversationItemUpsertedEvent(eventCursor: 'canonical', conversationId: summary.id,
        item: GatewayMessage(id: 'canonical-answer', itemId: 'answer', turnId: 'turn-1', role: MessageRole.assistant,
          kind: 'message', content: 'final answer', createdAt: DateTime(2026), isStreaming: false)));
      expect(detail.messages.map((m) => m.content), ['final answer', 'next question']);
      detail = detail.rejectStagedUserInput('next');
      expect(detail.messages.map((m) => m.content), ['final answer']);
    });

    test('terminal retains output and canonical item replaces it in place', () {
      var detail = ConversationDetail(summary: summary).apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-8',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          itemId: 'item-1',
          contentId: 'item-1:text',
          kind: 'text',
          delta: 'done',
        ),
      );

      detail = detail.apply(
        TurnUpsertedEvent(
          eventCursor: 'event-9',
          turn: TurnTask(
            id: 'turn-1',
            providerId: 'codex',
            conversationId: 'conversation-1',
            status: TurnStatus.completed,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
            completedAt: DateTime.fromMillisecondsSinceEpoch(
              3000,
              isUtc: true,
            ),
          ),
        ),
      );

      expect(detail.liveOutputMessages.single.isStreaming, isFalse);
      expect(detail.turns.single.status, TurnStatus.completed);

      final committed = GatewayMessage(
        id: 'history',
        itemId: 'item-1',
        turnId: 'turn-1',
        role: MessageRole.assistant,
        kind: 'text',
        content: 'committed',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
        isStreaming: false,
      );
      detail = detail.apply(ConversationItemUpsertedEvent(
        eventCursor: 'canonical', conversationId: summary.id, item: committed));
      expect(detail.committedMessages, [committed]);
      expect(detail.liveOutputMessages, isEmpty);
    });

    test('item upsert replaces matching live output without waiting for refresh', () {
      var detail = ConversationDetail(summary: summary).apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'delta',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          itemId: 'command-1',
          contentId: 'command-1:output',
          kind: 'output',
          delta: 'partial',
        ),
      );
      final completed = GatewayMessage(
        id: 'routed-command-1',
        itemId: 'command-1',
        turnId: 'turn-1',
        role: MessageRole.system,
        kind: 'command',
        content: 'done',
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        isStreaming: false,
        status: 'completed',
      );

      detail = detail.apply(ConversationItemUpsertedEvent(
        eventCursor: 'item-completed',
        conversationId: 'conversation-1',
        item: completed,
      ));

      expect(detail.committedMessages, [completed]);
      expect(detail.liveOutputMessages, isEmpty);
      expect(detail.lastEventCursor, 'item-completed');
    });

    test('upserts approval lifecycle events instead of dropping them', () {
      var detail = ConversationDetail(summary: summary).apply(
        ApprovalChangedEvent(
          eventCursor: 'approval-requested',
          conversationId: 'conversation-1',
          approval: GatewayMessage(
            id: 'approval-1',
            turnId: 'turn-1',
            role: MessageRole.system,
            kind: 'approval',
            content: 'Allow command?',
            createdAt:
                DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
            isStreaming: false,
            approvalStatus: 'pending',
          ),
        ),
      );
      detail = detail.apply(
        ApprovalChangedEvent(
          eventCursor: 'approval-resolved',
          conversationId: 'conversation-1',
          approval: GatewayMessage(
            id: 'approval-1',
            turnId: 'turn-1',
            role: MessageRole.system,
            kind: 'approval',
            content: 'Allow command?',
            createdAt:
                DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
            isStreaming: false,
            approvalStatus: 'approved',
          ),
        ),
      );

      expect(detail.committedMessages, hasLength(1));
      expect(detail.committedMessages.single.approvalStatus, 'approved');
      expect(detail.lastEventCursor, 'approval-resolved');
    });

    test('does not merge equal content ids from different routed turns', () {
      var detail = ConversationDetail(summary: summary);
      for (final turnId in ['turn-a', 'turn-b']) {
        detail = detail.apply(TurnOutputDeltaEvent(
          eventCursor: 'cursor-$turnId',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: turnId,
          itemId: 'same-item',
          contentId: 'same-item:text',
          kind: 'text',
          delta: turnId,
        ));
      }
      expect(detail.liveOutputMessages, hasLength(2));
      expect(detail.liveOutputMessages.map((message) => message.turnId), ['turn-a', 'turn-b']);
    });

    test('ignores events for another conversation', () {
      final detail = ConversationDetail(summary: summary);
      final next = detail.apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-8',
          providerId: 'codex',
          conversationId: 'conversation-2',
          turnId: 'turn-2',
          itemId: 'item-2',
          contentId: 'item-2:text',
          kind: 'text',
          delta: 'unrelated',
        ),
      );

      expect(identical(next, detail), isTrue);
    });

    test('discards a replayed delta already committed by the snapshot', () {
      final committed = GatewayMessage(
        id: 'history-item',
        itemId: 'item-1',
        turnId: 'turn-1',
        role: MessageRole.assistant,
        kind: 'message',
        content: 'committed body',
        contentIds: const ['item-1:text'],
        createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        isStreaming: false,
      );
      final detail = ConversationDetail(
        summary: summary,
        committedMessages: [committed],
      ).apply(
        const TurnOutputDeltaEvent(
          eventCursor: 'event-after-snapshot',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          itemId: 'item-1',
          contentId: 'item-1:text',
          kind: 'text',
          delta: 'committed body',
        ),
      );

      expect(detail.committedMessages, [committed]);
      expect(detail.liveOutputMessages, isEmpty);
      expect(detail.lastEventCursor, 'event-after-snapshot');
    });

    test('suppresses deltas by content identity across every committed variant', () {
      const ids = [
        'content:text',
        'content:reasoning',
        'content:output',
        'content:activity',
        'content:json',
        'content:image',
        'content:audio',
        'content:link',
        'content:embedded',
      ];
      var detail = ConversationDetail(
        summary: summary,
        committedMessages: [
          GatewayMessage(
            id: 'canonical-item',
            turnId: 'turn-1',
            role: MessageRole.system,
            kind: 'tool',
            content: '',
            contentIds: ids,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
            isStreaming: false,
          ),
        ],
      );

      for (final id in ids) {
        detail = detail.apply(TurnOutputDeltaEvent(
          eventCursor: 'cursor-$id',
          providerId: 'codex',
          conversationId: 'conversation-1',
          turnId: 'turn-1',
          itemId: 'canonical-item',
          contentId: id,
          kind: 'output',
          delta: 'different text must not drive deduplication',
        ));
      }

      expect(detail.liveOutputMessages, isEmpty);
      expect(detail.committedMessages.single.contentIds, ids);
    });

    test('accepts a canonical turn without fabricating a user item', () {
      final turn = TurnTask(
        id: 'turn-accepted',
        providerId: 'codex',
        conversationId: summary.id,
        status: TurnStatus.queued,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(4000, isUtc: true),
      );

      final detail = ConversationDetail(summary: summary).accept(
        TurnSendReceipt(
          clientRequestId: 'request-without-item',
          turn: turn,
          inputItem: null,
          effectiveSelection: const TurnSendSelection(),
        ),
      );

      expect(detail.committedMessages, isEmpty);
      expect(detail.turns.single.id, turn.id);
      expect(
        detail.turns.single.clientRequestId,
        'request-without-item',
      );
      expect(detail.activeTurn?.id, turn.id);
    });

    test('keeps a staged user input when the accepted turn has no user item', () {
      final createdAt =
          DateTime.fromMillisecondsSinceEpoch(3500, isUtc: true);
      final turn = TurnTask(
        id: 'turn-accepted',
        providerId: 'codex',
        conversationId: summary.id,
        status: TurnStatus.queued,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(4000, isUtc: true),
      );

      final detail = ConversationDetail(summary: summary)
          .stageUserInput(
            clientRequestId: 'request-without-item',
            text: 'show this immediately',
            createdAt: createdAt,
          )
          .accept(
            TurnSendReceipt(
              clientRequestId: 'request-without-item',
              turn: turn,
              inputItem: null,
              effectiveSelection: const TurnSendSelection(),
            ),
          );

      expect(detail.committedMessages, hasLength(1));
      expect(detail.committedMessages.single.role, MessageRole.user);
      expect(detail.committedMessages.single.content, 'show this immediately');
      expect(detail.committedMessages.single.turnId, turn.id);
      expect(detail.committedMessages.single.createdAt, createdAt);
    });

    test('replaces a staged input when its canonical item arrives after ack', () {
      final turn = TurnTask(
        id: 'turn-after-ack',
        providerId: 'codex',
        conversationId: summary.id,
        status: TurnStatus.running,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(4000, isUtc: true),
      );
      final canonical = GatewayMessage(
        id: 'routed-item-after-ack',
        itemId: 'item-after-ack',
        turnId: turn.id,
        role: MessageRole.user,
        kind: 'message',
        content: 'same text',
        createdAt: DateTime.fromMillisecondsSinceEpoch(4100, isUtc: true),
        isStreaming: false,
      );

      var detail = ConversationDetail(summary: summary)
          .stageUserInput(
            clientRequestId: 'request-after-ack',
            text: 'same text',
            createdAt:
                DateTime.fromMillisecondsSinceEpoch(3900, isUtc: true),
          )
          .accept(TurnSendReceipt(
            clientRequestId: 'request-after-ack',
            turn: turn,
            inputItem: null,
            effectiveSelection: const TurnSendSelection(),
          ));

      detail = detail.apply(ConversationItemUpsertedEvent(
        eventCursor: 'canonical-after-ack',
        conversationId: summary.id,
        item: canonical,
      ));
      detail = detail.apply(ConversationItemUpsertedEvent(
        eventCursor: 'canonical-after-ack-replayed',
        conversationId: summary.id,
        item: canonical,
      ));

      expect(detail.committedMessages, hasLength(1));
      expect(detail.committedMessages.single.id, canonical.id);
      expect(detail.committedMessages.single.itemId, canonical.itemId);
    });

    test('removes a staged input when its canonical item arrives before ack', () {
      final turn = TurnTask(
        id: 'turn-before-ack',
        providerId: 'codex',
        conversationId: summary.id,
        status: TurnStatus.running,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(5000, isUtc: true),
      );
      final canonical = GatewayMessage(
        id: 'routed-item-before-ack',
        itemId: 'item-before-ack',
        turnId: turn.id,
        role: MessageRole.user,
        kind: 'message',
        content: 'arrived early',
        createdAt: DateTime.fromMillisecondsSinceEpoch(5100, isUtc: true),
        isStreaming: false,
      );

      var detail = ConversationDetail(summary: summary).stageUserInput(
        clientRequestId: 'request-before-ack',
        text: 'arrived early',
        createdAt: DateTime.fromMillisecondsSinceEpoch(4900, isUtc: true),
      );
      detail = detail.apply(ConversationItemUpsertedEvent(
        eventCursor: 'canonical-before-ack',
        conversationId: summary.id,
        item: canonical,
      ));
      detail = detail.accept(TurnSendReceipt(
        clientRequestId: 'request-before-ack',
        turn: turn,
        inputItem: null,
        effectiveSelection: const TurnSendSelection(),
      ));

      expect(detail.committedMessages, [canonical]);
    });

    test('canonical ack remains idempotent with an item event', () {
      final turn = TurnTask(
        id: 'turn-canonical-ack',
        providerId: 'codex',
        conversationId: summary.id,
        status: TurnStatus.running,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(6000, isUtc: true),
      );
      final canonical = GatewayMessage(
        id: 'routed-item-canonical-ack',
        itemId: 'item-canonical-ack',
        turnId: turn.id,
        role: MessageRole.user,
        kind: 'message',
        content: 'canonical in ack',
        createdAt: DateTime.fromMillisecondsSinceEpoch(6100, isUtc: true),
        isStreaming: false,
      );

      var detail = ConversationDetail(summary: summary)
          .stageUserInput(
            clientRequestId: 'request-canonical-ack',
            text: 'canonical in ack',
            createdAt:
                DateTime.fromMillisecondsSinceEpoch(5900, isUtc: true),
          )
          .accept(TurnSendReceipt(
            clientRequestId: 'request-canonical-ack',
            turn: turn,
            inputItem: canonical,
            effectiveSelection: const TurnSendSelection(),
          ));
      detail = detail.apply(ConversationItemUpsertedEvent(
        eventCursor: 'canonical-ack-replayed',
        conversationId: summary.id,
        item: canonical,
      ));

      expect(detail.committedMessages, [canonical]);
    });

    test('keeps identical user text from different turns distinct', () {
      var detail = ConversationDetail(summary: summary);
      for (final suffix in ['one', 'two']) {
        final turn = TurnTask(
          id: 'turn-$suffix',
          providerId: 'codex',
          conversationId: summary.id,
          status: TurnStatus.running,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(
            suffix == 'one' ? 7000 : 8000,
            isUtc: true,
          ),
        );
        detail = detail
            .stageUserInput(
              clientRequestId: 'request-$suffix',
              text: 'identical',
              createdAt: turn.updatedAt,
            )
            .accept(TurnSendReceipt(
              clientRequestId: 'request-$suffix',
              turn: turn,
              inputItem: null,
              effectiveSelection: const TurnSendSelection(),
            ))
            .apply(ConversationItemUpsertedEvent(
              eventCursor: 'canonical-$suffix',
              conversationId: summary.id,
              item: GatewayMessage(
                id: 'routed-item-$suffix',
                itemId: 'item-$suffix',
                turnId: turn.id,
                role: MessageRole.user,
                kind: 'message',
                content: 'identical',
                createdAt: turn.updatedAt,
                isStreaming: false,
              ),
            ));
      }

      expect(detail.committedMessages, hasLength(2));
      expect(
        detail.committedMessages.map((message) => message.turnId),
        ['turn-one', 'turn-two'],
      );
    });

    for (final terminalStatus in [TurnStatus.interrupted, TurnStatus.failed]) {
      test('terminal $terminalStatus survives a stale running snapshot', () {
        final running = TurnTask(
          id: 'turn-terminal',
          providerId: 'codex',
          conversationId: summary.id,
          status: TurnStatus.running,
          updatedAt: DateTime.fromMillisecondsSinceEpoch(9000, isUtc: true),
        );
        final staleSummary = ConversationSummary(
          id: summary.id,
          providerId: summary.providerId,
          title: summary.title,
          status: ConversationStatus.running,
          permissionLevel: summary.permissionLevel,
          createdAt: summary.createdAt,
          updatedAt: running.updatedAt,
          activeTurn: running,
        );
        var detail = ConversationDetail(
          summary: staleSummary,
          turns: [running],
        ).apply(TurnUpsertedEvent(
          eventCursor: 'terminal-$terminalStatus',
          turn: TurnTask(
            id: running.id,
            providerId: running.providerId,
            conversationId: running.conversationId,
            status: terminalStatus,
            updatedAt: running.updatedAt,
            completedAt: running.updatedAt,
          ),
        ));

        detail = detail.prependHistory(
          ConversationDetail(summary: staleSummary, turns: [running]),
        );

        expect(detail.activeTurn, isNull);
        expect(detail.turns.single.status, terminalStatus);
        expect(
          detail.effectiveStatus,
          terminalStatus == TurnStatus.failed
              ? ConversationStatus.error
              : ConversationStatus.idle,
        );
      });
    }
  });

}
