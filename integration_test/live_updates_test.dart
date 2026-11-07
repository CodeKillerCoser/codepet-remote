import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:codepet_remote/application/notifications/live_update_coordinator.dart';
import 'package:codepet_remote/core/domain/notification.dart';
import 'package:codepet_remote/notifications/local_notification_adapter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native live notification updates one id and cancels', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('Live Updates probe'))),
    );
    final adapter = LocalNotificationAdapter();
    final opened = Completer<NotificationTarget>();
    await adapter.initialize((target) {
      if (!opened.isCompleted) opened.complete(target);
    });
    if (!await adapter.isAllowed()) {
      debugPrint('LIVE_READY_FOR_PERMISSION');
      expect(await adapter.requestPermission(), isTrue);
    }
    const target = NotificationTarget(
      deviceId: 'probe-host',
      providerId: 'probe-provider',
      conversationId: 'probe-conversation',
      turnId: 'probe-turn',
    );
    const running = LiveActivity(
      target,
      '任务运行中',
      '打开 CodePet Remote 查看最新任务状态',
      false,
    );
    await adapter.beginActivity(running.key);
    addTearDown(adapter.endActivity);
    expect(await adapter.showActivity(running), isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));
    var active = (await adapter.plugin.getActiveNotifications())
        .where((n) => n.id == 42)
        .toList();
    expect(active, hasLength(1));
    expect(active.single.title, '任务运行中');
    expect(active.single.channelId, 'live_tasks_v1');
    debugPrint('LIVE_CAPABILITIES: ${await adapter.liveCapabilities()}');
    const waiting = LiveActivity(
      NotificationTarget(
        deviceId: 'probe-host',
        providerId: 'probe-provider',
        conversationId: 'probe-conversation',
        turnId: 'probe-turn',
        requestId: 'probe-approval',
      ),
      '需要授权',
      '打开 CodePet Remote 查看最新任务状态',
      false,
    );
    expect(await adapter.showActivity(waiting), isTrue);
    await Future<void>.delayed(const Duration(seconds: 1));
    active = (await adapter.plugin.getActiveNotifications())
        .where((n) => n.id == 42)
        .toList();
    expect(active, hasLength(1));
    expect(active.single.title, '需要授权');
    if (const bool.fromEnvironment('LIVE_TAP_PROBE')) {
      debugPrint('LIVE_READY_FOR_TAP');
      final selected = await opened.future.timeout(const Duration(seconds: 30));
      expect(selected.deviceId, 'probe-host');
      expect(selected.turnId, 'probe-turn');
      expect(selected.requestId, 'probe-approval');
    }
    if (const bool.fromEnvironment('LIVE_DISMISS_PROBE')) {
      debugPrint('LIVE_READY_FOR_DISMISS');
      await Future<void>.delayed(const Duration(seconds: 20));
      expect(await adapter.showActivity(running), isFalse);
      expect(
        (await adapter.plugin.getActiveNotifications()).where(
          (n) => n.id == 42,
        ),
        isEmpty,
      );
    }
    await adapter.endActivity();
    expect(
      (await adapter.plugin.getActiveNotifications()).where((n) => n.id == 42),
      isEmpty,
    );
  });
}
