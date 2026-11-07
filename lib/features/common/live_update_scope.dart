import 'package:flutter/material.dart';

import '../../application/notifications/live_update_coordinator.dart';
import '../../core/domain/models.dart';
import '../../core/domain/notification.dart';

class LiveUpdateScope extends InheritedWidget {
  const LiveUpdateScope({
    super.key,
    required super.child,
    required this.coordinator,
    required this.follow,
    required this.capabilities,
    required this.settings,
  });
  final LiveUpdateCoordinator? coordinator;
  final Future<void> Function(NotificationTarget, TurnTask, bool) follow;
  final Future<Map<String, dynamic>> Function() capabilities;
  final Future<void> Function() settings;
  static LiveUpdateScope? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LiveUpdateScope>();
  @override
  bool updateShouldNotify(LiveUpdateScope oldWidget) => true;
}
