import 'dart:convert';
import 'package:codepet_remote/application/notifications/live_update_coordinator.dart';

import 'package:codepet_remote/application/notifications/notification_coordinator.dart';
import 'package:codepet_remote/application/ports/system_notifications.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/notification.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 11, 5);
const route = RoutedResourceId(
  providerId: 'provider',
  nativeResourceId: 'conversation',
);

void main() {
  late _System system;
  late _Store store;
  late NotificationCoordinator coordinator;
  setUp(() async {
    system = _System();
    store = _Store();
    coordinator = NotificationCoordinator(
      system: system,
      store: store,
      now: () => now,
    );
    await coordinator.initialize();
    coordinator.foreground = false;
  });

  Future<void> send(GatewayEvent event, {String host = 'host'}) =>
      coordinator.event(host, 'Private machine', event, summary());

  test('visible conversation suppresses alerts but not explicitly followed status', () async {
    final liveSystem = _LiveSystem();
    final live = LiveUpdateCoordinator(liveSystem, now: () => now);
    coordinator = NotificationCoordinator(system: system, store: store, liveUpdates: live, now: () => now);
    await coordinator.initialize();
    const target = NotificationTarget(deviceId: 'host', providerId: 'provider', conversationId: 'conversation');
    coordinator.foreground = true;
    coordinator.visibleConversation = target.conversationKey;
    await live.follow(target, turn(TurnStatus.running).turn, preview: false);
    await send(approval('pending'));
    expect(system.shown, isEmpty);
    expect(liveSystem.shown.last.title, '需要授权');
    await coordinator.acknowledge(target);
    expect(live.target, isNotNull);
    coordinator.foreground = false;
    await send(turn(TurnStatus.completed));
    expect(live.target, isNull);
    expect(system.shown.single.kind, NoticeKind.outcome);
    await live.stop();
  });

  test(
    'completion with omitted optional timestamps is still a live event',
    () async {
      await send(
        turn(TurnStatus.completed, at: DateTime.fromMillisecondsSinceEpoch(0)),
      );
      expect(system.shown.single.title, '任务已完成');
    },
  );

  test(
    'pending request details update silently under the same notification id',
    () async {
      await coordinator.updatePreferences(
        const NotificationPreferences(interventions: true, preview: true),
      );
      await send(approval('pending'));
      await send(approval('pending', title: 'Updated command'));
      expect(system.shown, hasLength(2));
      expect(system.shown.last.id, system.shown.first.id);
      expect(system.shown.last.silent, isTrue);
      expect(system.shown.last.body, contains('Updated command'));
      await coordinator.acknowledge(system.shown.last.target);
      await send(approval('pending', title: 'Another update'));
      expect(system.shown, hasLength(2));
    },
  );

  test(
    'completion is delivered once across reconnect and process restart',
    () async {
      await send(turn(TurnStatus.completed));
      await send(turn(TurnStatus.completed, cursor: 'replay'));
      coordinator = NotificationCoordinator(
        system: system,
        store: store,
        now: () => now,
      );
      await coordinator.initialize();
      coordinator.foreground = false;
      await send(turn(TurnStatus.completed, cursor: 'restart'));
      expect(system.shown, hasLength(1));
      expect(system.shown.single.target.conversationId, 'conversation');
      expect(system.shown.single.title, '任务已完成');
      expect(system.shown.single.body, isNot(contains('Private')));
      expect(jsonEncode(store.ledger), isNot(contains('Secret result')));
    },
  );

  test(
    'device identity is part of deduplication and notification ids',
    () async {
      await send(turn(TurnStatus.completed));
      await send(turn(TurnStatus.completed), host: 'other-host');
      expect(system.shown, hasLength(2));
      expect(system.shown.map((n) => n.id).toSet(), hasLength(2));
    },
  );

  test(
    'only terminal outcomes alert; interruptions and stale history stay quiet',
    () async {
      await send(turn(TurnStatus.running));
      await send(turn(TurnStatus.waitingApproval));
      await send(turn(TurnStatus.interrupted));
      await send(
        turn(
          TurnStatus.completed,
          id: 'old',
          at: now.subtract(const Duration(days: 1)),
        ),
      );
      await coordinator.snapshot('host', 'Host', [
        summary(status: ConversationStatus.idle),
      ]);
      expect(system.shown, isEmpty);
      await send(turn(TurnStatus.failed, id: 'failure'));
      expect(system.shown.single.title, '任务执行失败');
    },
  );

  test(
    'visible conversation suppresses alerts without suppressing another device',
    () async {
      coordinator.foreground = true;
      coordinator.visibleConversation = const NotificationTarget(
        deviceId: 'host',
        providerId: 'provider',
        conversationId: 'conversation',
      ).conversationKey;
      await send(turn(TurnStatus.completed));
      await send(turn(TurnStatus.completed), host: 'other-host');
      expect(system.shown.single.target.deviceId, 'other-host');
    },
  );

  test(
    'approval uses native routing and is removed when resolved elsewhere',
    () async {
      await coordinator.event('host', 'Host', approval('pending'), null);
      final notice = system.shown.single;
      expect(notice.target.conversationId, 'conversation');
      await coordinator.acknowledge(notice.target);
      await send(approval('pending', cursor: 'still-pending'));
      expect(system.shown, hasLength(1));
      await send(approval('resolved'));
      expect(system.cancelled, contains(notice.id));
      await send(approval('pending', cursor: 'late-pending'));
      expect(system.shown, hasLength(1));
    },
  );

  test('resolved-before-pending and terminal-before-pending cannot resurrect requests', () async {
    await send(approval('resolved'));
    await send(approval('pending'));
    await send(turn(TurnStatus.completed));
    await send(approval('pending', id: 'other-approval'));
    expect(system.shown, hasLength(1));
    expect(system.shown.single.kind, NoticeKind.outcome);
  });

  test(
    'summary placeholders are replaced silently by structured approvals',
    () async {
      await coordinator.snapshot('host', 'Host', [
        summary(status: ConversationStatus.waitingApproval),
      ]);
      final placeholder = system.shown.single;
      await send(approval('pending'));
      expect(system.shown, hasLength(2));
      expect(system.shown.last.silent, isTrue);
      expect(system.cancelled, contains(placeholder.id));
      await coordinator.snapshot('host', 'Host', [
        summary(status: ConversationStatus.waitingApproval),
      ]);
      expect(system.shown, hasLength(2));
    },
  );

  test(
    'waiting input is one request per waiting episode, not per metadata change',
    () async {
      Future<void> snapshot(ConversationStatus status, int seconds) =>
          coordinator.snapshot('host', 'Host', [
            summary(
              status: status,
              at: now.add(Duration(seconds: seconds)),
            ),
          ]);
      await snapshot(ConversationStatus.waitingUserInput, 0);
      await snapshot(ConversationStatus.waitingUserInput, 1);
      expect(system.shown, hasLength(1));
      await snapshot(ConversationStatus.running, 2);
      await snapshot(ConversationStatus.waitingUserInput, 0);
      expect(system.shown, hasLength(1));
      await snapshot(ConversationStatus.waitingUserInput, 3);
      expect(system.shown, hasLength(2));
    },
  );

  test(
    'terminal for an old turn does not remove a newer intervention',
    () async {
      await send(approval('pending', turnId: 'new-turn'));
      await send(turn(TurnStatus.completed));
      expect(system.cancelled, isNot(contains(system.shown.first.id)));
    },
  );

  test(
    'permission denial does not fail the event stream; grants allow retry',
    () async {
      system.allowed = false;
      await send(approval('pending'));
      expect(system.shown, isEmpty);
      system.allowed = true;
      await send(approval('pending'));
      expect(system.shown, hasLength(1));
    },
  );

  test('delivery failures can be retried without corrupting persisted delivery state', () async {
    system.fail = true;
    await send(turn(TurnStatus.completed));
    expect(system.shown, isEmpty);
    system.fail = false;
    await send(turn(TurnStatus.completed));
    expect(system.shown, hasLength(1));
  });

  test('disabling preview removes exposed notifications and forgetting clears device state', () async {
    await coordinator.updatePreferences(
      const NotificationPreferences(
        outcomes: true,
        interventions: true,
        preview: true,
      ),
    );
    await send(turn(TurnStatus.completed));
    expect(system.shown.single.body, contains('Secret result'));
    await coordinator.updatePreferences(
      const NotificationPreferences(outcomes: true, interventions: true),
    );
    expect(system.cancelled, contains(system.shown.single.id));
    await coordinator.forgetDevice('host');
    expect(store.ledger['entries'], isEmpty);
  });

  test('malformed notification tap payloads are rejected', () {
    expect(NotificationTarget.parse('{invalid'), isNull);
    expect(NotificationTarget.parse('{"deviceId":"host"}'), isNull);
    final target = const NotificationTarget(
      deviceId: 'host',
      providerId: 'provider',
      conversationId: 'id',
    );
    expect(
      NotificationTarget.parse(jsonEncode(target.toJson()))?.conversationKey,
      target.conversationKey,
    );
  });
}

ConversationSummary summary({
  ConversationStatus status = ConversationStatus.running,
  DateTime? at,
}) => ConversationSummary(
  id: route.key,
  providerId: 'provider',
  title: 'Private conversation',
  status: status,
  permissionLevel: PermissionLevel.readOnly,
  createdAt: now,
  updatedAt: at ?? now,
  resource: route,
);
TurnUpsertedEvent turn(
  TurnStatus status, {
  String id = 'turn',
  String cursor = 'turn-event',
  DateTime? at,
}) => TurnUpsertedEvent(
  eventCursor: cursor,
  turn: TurnTask(
    id: id,
    providerId: 'provider',
    conversationId: route.key,
    conversationResource: route,
    status: status,
    updatedAt: at ?? now,
    displaySummary: 'Secret result',
  ),
);
ApprovalChangedEvent approval(
  String status, {
  String id = 'approval',
  String turnId = 'turn',
  String cursor = 'approval-event',
  String title = 'Run command',
}) => ApprovalChangedEvent(
  eventCursor: cursor,
  conversationId: route.key,
  approval: GatewayMessage(
    id: id,
    turnId: turnId,
    role: MessageRole.system,
    kind: 'approval',
    content: 'secret command',
    title: title,
    approvalStatus: status,
    createdAt: now,
    isStreaming: false,
    resource: RoutedResourceId(providerId: 'provider', nativeResourceId: id),
  ),
);

class _System implements SystemNotifications {
  bool allowed = true;
  bool fail = false;
  final shown = <RemoteNotice>[];
  final cancelled = <int>[];
  @override
  Future<bool> isAllowed() async => allowed;
  @override
  Future<bool> requestPermission() async => allowed;
  @override
  Future<void> show(RemoteNotice notice) async {
    if (fail) throw StateError('delivery failed');
    shown.add(notice);
  }

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
  }

  @override
  Future<void> setKeepConnected(bool enabled) async {}
}

class _Store implements NotificationStore {
  Map<String, dynamic> ledger = {};
  NotificationPreferences preferences = const NotificationPreferences(
    outcomes: true,
    interventions: true,
  );
  @override
  Future<Map<String, dynamic>> loadLedger() async => ledger;
  @override
  Future<void> saveLedger(Map<String, dynamic> value) async {
    ledger = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
  }

  @override
  Future<NotificationPreferences> loadPreferences() async => preferences;
  @override
  Future<void> savePreferences(NotificationPreferences value) async {
    preferences = value;
  }
}

class _LiveSystem implements LiveUpdates {
  final shown = <LiveActivity>[];
  @override Future<void> beginActivity(String key) async {}
  @override Future<void> endActivity() async {}
  @override Future<bool> showActivity(LiveActivity activity) async { shown.add(activity); return true; }
}
