import 'package:codepet_remote/app/app_notifications.dart';
import 'package:codepet_remote/app/codepet_remote_app.dart';
import 'package:codepet_remote/application/notifications/notification_coordinator.dart';
import 'package:codepet_remote/application/ports/system_notifications.dart';
import 'package:codepet_remote/core/domain/notification.dart';
import 'package:codepet_remote/features/conversations/conversation_detail_screen.dart';
import 'package:codepet_remote/notifications/local_notification_adapter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'cold launch target waits for devices and opens the correct session',
    (tester) async {
      final adapter = _Adapter();
      final coordinator = NotificationCoordinator(
        system: adapter,
        store: _Store(),
      );
      await coordinator.initialize();
      final notifications = AppNotifications(adapter, coordinator)
        ..pendingTarget = const NotificationTarget(
          deviceId: 'demo-laptop',
          providerId: 'codex-demo',
          conversationId: 'laptop-unscoped',
        );
      await tester.pumpWidget(
        CodePetRemoteApp(
          includeDemoDevices: true,
          notifications: notifications,
        ),
      );
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final screen = tester.widget<ConversationDetailScreen>(
        find.byType(ConversationDetailScreen),
      );
      expect(screen.session.device.deviceId, 'demo-laptop');
      expect(screen.conversation.id, 'laptop-unscoped');
      expect(
        coordinator.visibleConversation,
        const NotificationTarget(
          deviceId: 'demo-laptop',
          providerId: 'codex-demo',
          conversationId: 'laptop-unscoped',
        ).conversationKey,
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('a revoked device notification does not open another device', (
    tester,
  ) async {
    final adapter = _Adapter();
    final coordinator = NotificationCoordinator(
      system: adapter,
      store: _Store(),
    );
    await coordinator.initialize();
    final notifications = AppNotifications(adapter, coordinator)
      ..pendingTarget = const NotificationTarget(
        deviceId: 'forgotten-host',
        providerId: 'codex-demo',
        conversationId: 'laptop-unscoped',
      );
    await tester.pumpWidget(
      CodePetRemoteApp(includeDemoDevices: true, notifications: notifications),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ConversationDetailScreen), findsNothing);
    expect(find.text('暂时无法打开此会话，请检查设备连接后重试'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}

class _Adapter extends LocalNotificationAdapter {
  @override
  Future<bool> isAllowed() async => true;
  @override
  Future<void> cancel(int id) async {}
  @override
  Future<void> show(RemoteNotice notice) async {}
  @override
  Future<void> setKeepConnected(bool enabled) async {}
}

class _Store implements NotificationStore {
  @override
  Future<Map<String, dynamic>> loadLedger() async => {};
  @override
  Future<void> saveLedger(Map<String, dynamic> ledger) async {}
  @override
  Future<NotificationPreferences> loadPreferences() async =>
      const NotificationPreferences();
  @override
  Future<void> savePreferences(NotificationPreferences preferences) async {}
}
