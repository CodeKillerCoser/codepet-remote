import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../application/notifications/notification_coordinator.dart';
import '../application/notifications/live_update_coordinator.dart';
import '../core/domain/notification.dart';
import '../diagnostics/app_log.dart';
import '../notifications/local_notification_adapter.dart';

class AppNotifications with WidgetsBindingObserver {
  AppNotifications(this.adapter, this.coordinator) {
    observer = _NotificationRouteObserver(coordinator);
    coordinator.foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
  }
  final LocalNotificationAdapter adapter;
  final NotificationCoordinator coordinator;
  late final NavigatorObserver observer;
  NotificationTarget? pendingTarget;
  void Function(NotificationTarget)? onOpen;
  bool hasSessions = false;
  bool _serviceEnabled = false;
  Future<void> _serviceUpdate = Future.value();

  static Future<AppNotifications> create() async {
    final adapter = LocalNotificationAdapter();
    final coordinator = NotificationCoordinator(
      system: adapter,
      liveUpdates: LiveUpdateCoordinator(adapter),
      store: PreferencesNotificationStore(
        await SharedPreferences.getInstance(),
      ),
      logger: AppLog.named('notifications'),
    );
    await coordinator.initialize();
    final runtime = AppNotifications(adapter, coordinator);
    runtime.pendingTarget = await adapter.initialize(runtime._open);
    return runtime;
  }

  void _open(NotificationTarget target) {
    final callback = onOpen;
    if (callback == null) {
      pendingTarget = target;
    } else {
      callback(target);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    coordinator.foreground = state == AppLifecycleState.resumed;
    if (coordinator.foreground) unawaited(syncConnectionService());
  }

  Future<NotificationPreferences> changePreferences(
    NotificationPreferences value,
  ) async {
    if ((value.outcomes || value.interventions || value.keepConnected) &&
        !await adapter.isAllowed() &&
        !await adapter.requestPermission()) {
      throw StateError('请在系统设置中允许通知后重试');
    }
    // Start while the user is interacting with the app; Android restricts
    // starting a foreground service from the background.
    final previous = coordinator.preferences;
    await coordinator.updatePreferences(value);
    try {
      await syncConnectionService();
    } catch (_) {
      await coordinator.updatePreferences(previous);
      rethrow;
    }
    return value;
  }

  Future<void> syncConnectionService() {
    final next = _serviceUpdate.then((_) async {
      final enabled = coordinator.preferences.keepConnected && hasSessions;
      if (_serviceEnabled == enabled) return;
      if (enabled && (!coordinator.foreground || !await adapter.isAllowed())) {
        return;
      }
      await adapter.setKeepConnected(enabled);
      _serviceEnabled = enabled;
    });
    _serviceUpdate = next.catchError((Object error) {
      AppLog.named('notifications')
          .warning('Background connection service failed', error: error);
    });
    return next;
  }

  void dispose() {
    onOpen = null;
    WidgetsBinding.instance.removeObserver(this);
    coordinator.dispose();
    unawaited(adapter.setKeepConnected(false));
  }
}

class _NotificationRouteObserver extends NavigatorObserver {
  _NotificationRouteObserver(this.coordinator);
  final NotificationCoordinator coordinator;
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    final target = topRoute.settings.arguments;
    coordinator.visibleConversation = target is NotificationTarget
        ? target.conversationKey
        : null;
    if (target is NotificationTarget) {
      unawaited(coordinator.acknowledge(target));
    }
  }
}
