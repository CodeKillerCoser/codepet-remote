import 'dart:async';

import 'package:codepet_remote/app/app_notifications.dart';
import 'package:codepet_remote/core/domain/notification.dart';
import 'package:codepet_remote/core/domain/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Run on an isolated Android emulator with POST_NOTIFICATIONS already granted.
// The production package never generates these synthetic notices.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android channels, private notice payload, cancellation and connection service',
    (tester) async {
      final notifications = await AppNotifications.create();
      addTearDown(notifications.dispose);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Notification integration test')),
        ),
      );
      await tester.pumpAndSettle();
      if (!await notifications.adapter.isAllowed()) {
        debugPrint('NOTIFICATION_READY_FOR_PERMISSION');
        expect(await notifications.adapter.requestPermission(), isTrue);
      }
      const target = NotificationTarget(
        deviceId: 'test-host',
        providerId: 'test-provider',
        conversationId: 'test-conversation',
        turnId: 'test-turn',
        requestId: 'test-request',
      );
      await notifications.adapter.show(
        const RemoteNotice(
          id: 800001,
          target: target,
          kind: NoticeKind.intervention,
          title: '需要授权',
          body: '打开 CodePet Remote 查看并处理',
          preview: false,
        ),
      );
      final active = await notifications.adapter.plugin
          .getActiveNotifications();
      final notice = active.singleWhere((value) => value.id == 800001);
      expect(notice.title, '需要授权');
      expect(notice.body, '打开 CodePet Remote 查看并处理');
      expect(notice.channelId, 'interventions_v1');
      const tapProbe = bool.fromEnvironment('NOTIFICATION_TAP_PROBE');
      if (tapProbe) {
        final opened = Completer<NotificationTarget>();
        notifications.onOpen = (value) {
          if (!opened.isCompleted) opened.complete(value);
        };
        debugPrint('NOTIFICATION_READY_FOR_TAP');
        final selected = await opened.future.timeout(
          const Duration(seconds: 45),
        );
        expect(selected.conversationKey, target.conversationKey);
        expect(selected.requestId, target.requestId);
        await tester.pump(const Duration(milliseconds: 500));
      }
      await notifications.adapter.cancel(800001);
      expect(
        (await notifications.adapter.plugin.getActiveNotifications()).where(
          (n) => n.id == 800001,
        ),
        isEmpty,
      );

      notifications.hasSessions = true;
      expect(notifications.coordinator.foreground, isTrue);
      await notifications.changePreferences(
        const NotificationPreferences(keepConnected: true, outcomes: true),
      );
      for (var i = 0; i < 30; i++) {
        if ((await notifications.adapter.plugin.getActiveNotifications()).any(
          (n) => n.id == 1,
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        (await notifications.adapter.plugin.getActiveNotifications()).any(
          (n) => n.id == 1,
        ),
        isTrue,
      );
      if (tapProbe) {
        debugPrint('NOTIFICATION_READY_FOR_BACKGROUND');
        for (var i = 0; i < 100 && notifications.coordinator.foreground; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(notifications.coordinator.foreground, isFalse);
        // The external probe destroys the Activity after Home. The application
        // engine and direct-device event coordinator must still be available.
        await Future<void>.delayed(const Duration(seconds: 2));
        final reopened = Completer<NotificationTarget>();
        notifications.onOpen = (value) {
          if (!reopened.isCompleted) reopened.complete(value);
        };
        await notifications.coordinator.event(
          'test-host',
          'Test host',
          TurnUpsertedEvent(
            eventCursor: 'background-completion',
            turn: TurnTask(
              id: 'background-turn',
              providerId: 'test-provider',
              conversationId: 'test-conversation',
              status: TurnStatus.completed,
              updatedAt: DateTime.now(),
            ),
          ),
          null,
        );
        expect(
          (await notifications.adapter.plugin.getActiveNotifications()).any(
            (n) => n.title == '任务已完成',
          ),
          isTrue,
        );
        debugPrint('NOTIFICATION_POSTED_IN_BACKGROUND');
        final selected = await reopened.future.timeout(
          const Duration(seconds: 45),
        );
        expect(selected.turnId, 'background-turn');
        for (var i = 0; i < 50 && !notifications.coordinator.foreground; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(notifications.coordinator.foreground, isTrue);
      }
      await notifications.changePreferences(const NotificationPreferences());
      for (var i = 0; i < 30; i++) {
        if (!(await notifications.adapter.plugin.getActiveNotifications()).any(
          (n) => n.id == 1,
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(
        (await notifications.adapter.plugin.getActiveNotifications()).any(
          (n) => n.id == 1,
        ),
        isFalse,
      );
    },
  );
}
