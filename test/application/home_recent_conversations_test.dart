import 'package:codepet_remote/application/sessions/device_session.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.utc(2026, 9, 8);
  ConversationSummary item(
    String id,
    int days, {
    ConversationStatus status = ConversationStatus.idle,
    bool unread = false,
  }) => ConversationSummary(
    id: id,
    providerId: 'test',
    title: id,
    status: status,
    permissionLevel: PermissionLevel.readOnly,
    createdAt: now.subtract(Duration(days: days)),
    updatedAt: now.subtract(Duration(days: days)),
    readState: ConversationReadState(unread: unread, activityVersion: '1'),
  );

  test(
    'recent prioritizes ongoing tasks then unread, descending within groups',
    () {
      final result = homeRecentConversations([
        item('read-new', 0),
        item('unread-old', 40, unread: true),
        item('running-old', 60, status: ConversationStatus.running),
        item('waiting', 50, status: ConversationStatus.waitingApproval),
        item('input', 45, status: ConversationStatus.waitingUserInput),
        item('unread-new', 1, unread: true),
        item('read-old', 15),
        item('boundary', 14),
      ], now: now);
      expect(result.map((value) => value.id), [
        'input',
        'waiting',
        'running-old',
        'unread-new',
        'unread-old',
        'read-new',
        'boundary',
      ]);
    },
  );

  test(
    'reading old completed tasks removes them but retains ongoing tasks',
    () {
      final old = item('old', 30, unread: true);
      expect(homeRecentConversations([old], now: now), [old]);
      expect(
        homeRecentConversations([
          old.withReadState(
            const ConversationReadState(unread: false, activityVersion: '1'),
          ),
        ], now: now),
        isEmpty,
      );
      final running = item('running', 30, status: ConversationStatus.running);
      expect(homeRecentConversations([running], now: now), [running]);
    },
  );

  test('equal timestamps use stable routed identity', () {
    expect(
      homeRecentConversations([
        item('b', 0),
        item('a', 0),
      ], now: now).map((value) => value.id),
      ['a', 'b'],
    );
  });
}
