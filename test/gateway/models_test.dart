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

    test('keeps live output separate until a terminal snapshot is installed', () {
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

      expect(detail.liveOutputMessages.single.isStreaming, isTrue);
      expect(detail.turns.single.status, TurnStatus.completed);

      final committed = GatewayMessage(
        id: 'history',
        turnId: 'turn-1',
        role: MessageRole.assistant,
        kind: 'text',
        content: 'committed',
        createdAt: DateTime.fromMillisecondsSinceEpoch(3000, isUtc: true),
        isStreaming: false,
      );
      detail = detail.installCommittedSnapshot(
        ConversationDetail(summary: summary, committedMessages: [committed]),
        completedTurnId: 'turn-1',
      );
      expect(detail.committedMessages, [committed]);
      expect(detail.liveOutputMessages, isEmpty);
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
      expect(detail.turns, [turn]);
      expect(detail.activeTurn, turn);
    });
  });

}
