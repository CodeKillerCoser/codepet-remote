import 'package:flutter_test/flutter_test.dart';
import 'package:codepet_remote/application/notifications/live_update_coordinator.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:codepet_remote/core/domain/notification.dart';

const target = NotificationTarget(
  deviceId: 'a',
  providerId: 'p',
  conversationId: 'c',
  turnId: 't',
);
final start = DateTime.utc(2026, 11, 8);
TurnTask turn(TurnStatus status, {int seconds = 0, String id = 't'}) =>
    TurnTask(
      id: id,
      providerId: 'p',
      conversationId: 'c',
      status: status,
      updatedAt: start.add(Duration(seconds: seconds)),
      displaySummary: 'private command',
    );
InterventionRequest request(InterventionStatus status, {int seconds = 1}) =>
    InterventionRequest(
      target: const NotificationTarget(
        deviceId: 'a',
        providerId: 'p',
        conversationId: 'c',
        turnId: 't',
        requestId: 'r',
      ),
      kind: InterventionKind.approval,
      status: status,
      at: start.add(Duration(seconds: seconds)),
      summary: 'secret',
    );

class Platform implements LiveUpdates {
  final shown = <LiveActivity>[];
  int ended = 0;
  bool allowed = true;
  @override
  Future<void> beginActivity(String key) async {
    allowed = true;
  }

  @override
  Future<void> endActivity() async {
    ended++;
  }

  @override
  Future<bool> showActivity(LiveActivity activity) async {
    if (allowed) shown.add(activity);
    return allowed;
  }
}

void main() {
  late Platform platform;
  late LiveUpdateCoordinator coordinator;
  late DateTime now;
  setUp(() {
    now = start;
    platform = Platform();
    coordinator = LiveUpdateCoordinator(platform, now: () => now);
  });
  tearDown(() async {
    await coordinator.stop();
  });
  test('explicit follow, approval, resume and completion keep identity and privacy', () async {
    await coordinator.updateTurn(target, turn(TurnStatus.running));
    expect(platform.shown, isEmpty);
    await coordinator.follow(target, turn(TurnStatus.running), preview: false);
    final key = platform.shown.last.key;
    await coordinator.request(request(InterventionStatus.pending));
    expect(platform.shown.last.title, '需要授权');
    expect(platform.shown.last.target.requestId, 'r');
    expect(platform.shown.last.body, isNot(contains('secret')));
    await coordinator.request(request(InterventionStatus.resolved));
    await coordinator.updateTurn(target, turn(TurnStatus.running, seconds: 2));
    expect(platform.shown.last.target.requestId, isNull);
    expect(platform.shown.last.key, key);
    await coordinator.request(request(InterventionStatus.pending, seconds: 3));
    expect(platform.shown.last.title, '任务运行中');
    await coordinator.updateTurn(
      target,
      turn(TurnStatus.completed, seconds: 4),
    );
    expect(coordinator.target, isNull);
    final count = platform.shown.length;
    await coordinator.updateTurn(target, turn(TurnStatus.running, seconds: 5));
    expect(platform.shown, hasLength(count));
  });
  test(
    'old events and other devices cannot overwrite or end the selected turn',
    () async {
      await coordinator.follow(
        target,
        turn(TurnStatus.running, seconds: 2),
        preview: true,
      );
      await coordinator.updateTurn(target, turn(TurnStatus.failed, seconds: 1));
      await coordinator.updateTurn(
        const NotificationTarget(
          deviceId: 'b',
          providerId: 'p',
          conversationId: 'c',
        ),
        turn(TurnStatus.failed, seconds: 3),
      );
      expect(coordinator.target?.deviceId, 'a');
      expect(platform.shown, hasLength(1));
      await coordinator.setPreview(false);
      expect(platform.shown.last.body, isNot(contains('private')));
    },
  );
  test(
    'dismissal or disabled permission ends follow, later events never repin',
    () async {
      await coordinator.follow(
        target,
        turn(TurnStatus.running),
        preview: false,
      );
      platform.allowed = false;
      await coordinator.updateTurn(
        target,
        turn(TurnStatus.running, seconds: 1),
      );
      expect(coordinator.target, isNull);
      platform.allowed = true;
      await coordinator.updateTurn(
        target,
        turn(TurnStatus.running, seconds: 2),
      );
      expect(platform.shown, hasLength(1));
    },
  );
  test(
    'one selected turn replaces another and expires without fresh state',
    () async {
      await coordinator.follow(
        target,
        turn(TurnStatus.running),
        preview: false,
      );
      await coordinator.follow(
        target,
        turn(TurnStatus.running, id: 'other'),
        preview: false,
      );
      expect(coordinator.target?.turnId, 'other');
      await coordinator.updateTurn(
        target,
        turn(TurnStatus.completed, seconds: 1),
      );
      expect(coordinator.target?.turnId, 'other');
      now = start.add(const Duration(minutes: 3));
      await coordinator.expire();
      expect(coordinator.target, isNull);
    },
  );
  test(
    'input waiting, resume, newer turn and out-of-order snapshots',
    () async {
      ConversationSummary summary(
        ConversationStatus status,
        int seconds, {
        String id = 't',
      }) => ConversationSummary(
        id: 'c',
        providerId: 'p',
        title: 'private title',
        status: status,
        permissionLevel: PermissionLevel.readOnly,
        createdAt: start,
        updatedAt: start.add(Duration(seconds: seconds)),
        activeTurn: turn(TurnStatus.running, seconds: seconds, id: id),
      );
      await coordinator.follow(
        target,
        turn(TurnStatus.running),
        preview: false,
      );
      await coordinator.conversation(
        target,
        summary(ConversationStatus.waitingUserInput, 1),
      );
      expect(platform.shown.last.title, '需要补充信息');
      await coordinator.conversation(
        target,
        summary(ConversationStatus.running, 2),
      );
      await coordinator.conversation(
        target,
        summary(ConversationStatus.waitingUserInput, 1),
      );
      expect(platform.shown.last.title, '任务运行中');
      expect(platform.shown.last.target.requestId, isNull);
      await coordinator.conversation(
        target,
        summary(ConversationStatus.running, 3, id: 'new'),
      );
      expect(coordinator.target, isNull);
    },
  );

  for (final status in [TurnStatus.failed, TurnStatus.interrupted]) {
    test('$status ends the activity', () async {
      await coordinator.follow(
        target,
        turn(TurnStatus.running),
        preview: false,
      );
      await coordinator.updateTurn(target, turn(status, seconds: 1));
      expect(coordinator.target, isNull);
    });
  }
}
