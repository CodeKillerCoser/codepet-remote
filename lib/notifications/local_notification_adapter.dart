import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../application/ports/system_notifications.dart';
import '../core/domain/notification.dart';

class PreferencesNotificationStore implements NotificationStore {
  PreferencesNotificationStore(this.preferences);
  final SharedPreferences preferences;
  static const _ledgerKey = 'notification_ledger_v1';
  static const _preferencesKey = 'notification_preferences_v1';
  Map<String, dynamic> _read(String key) {
    try {
      return jsonDecode(preferences.getString(key) ?? '{}')
          as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  @override
  Future<Map<String, dynamic>> loadLedger() async => _read(_ledgerKey);
  @override
  Future<NotificationPreferences> loadPreferences() async =>
      NotificationPreferences.fromJson(_read(_preferencesKey));
  Future<void> _write(String key, Object value) async {
    if (!await preferences.setString(key, jsonEncode(value))) {
      throw StateError('Unable to persist notification state');
    }
  }

  @override
  Future<void> saveLedger(Map<String, dynamic> ledger) =>
      _write(_ledgerKey, ledger);
  @override
  Future<void> savePreferences(NotificationPreferences value) =>
      _write(_preferencesKey, value.toJson());
}

class LocalNotificationAdapter implements SystemNotifications {
  final plugin = FlutterLocalNotificationsPlugin();
  static const _connection = MethodChannel(
    'com.codepet.remote/background_connection',
  );
  static const outcomeChannel = AndroidNotificationChannel(
    'task_outcomes_v1',
    '任务结果',
    description: '任务完成或失败时提醒',
    importance: Importance.defaultImportance,
  );
  static const interventionChannel = AndroidNotificationChannel(
    'interventions_v1',
    '需要你处理',
    description: '等待授权、补充信息或确认时提醒',
    importance: Importance.high,
  );

  Future<NotificationTarget?> initialize(
    void Function(NotificationTarget) onOpen,
  ) async {
    if (!Platform.isAndroid) return null;
    await plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('ic_notification'),
      ),
      onDidReceiveNotificationResponse: (response) {
        final target = NotificationTarget.parse(response.payload);
        if (target != null) onOpen(target);
      },
    );
    final android = plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()!;
    await android.createNotificationChannel(outcomeChannel);
    await android.createNotificationChannel(interventionChannel);
    final launch = await plugin.getNotificationAppLaunchDetails();
    return launch?.didNotificationLaunchApp == true
        ? NotificationTarget.parse(launch?.notificationResponse?.payload)
        : null;
  }

  @override
  Future<bool> isAllowed() async =>
      Platform.isAndroid &&
      (await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.areNotificationsEnabled() ??
          false);
  @override
  Future<bool> requestPermission() async =>
      Platform.isAndroid &&
      (await plugin
              .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin
              >()
              ?.requestNotificationsPermission() ??
          false);
  @override
  Future<void> show(RemoteNotice notice) async {
    final channel = notice.kind == NoticeKind.intervention
        ? interventionChannel
        : outcomeChannel;
    await plugin.show(
      id: notice.id,
      title: notice.title,
      body: notice.body,
      notificationDetails: NotificationDetails(
        android: AndroidNotificationDetails(
          channel.id,
          channel.name,
          channelDescription: channel.description,
          importance: channel.importance,
          priority: notice.kind == NoticeKind.intervention
              ? Priority.high
              : Priority.defaultPriority,
          visibility: notice.preview
              ? NotificationVisibility.private
              : NotificationVisibility.public,
          onlyAlertOnce: true,
          silent: notice.silent,
          autoCancel: true,
          category: notice.kind == NoticeKind.intervention
              ? AndroidNotificationCategory.reminder
              : AndroidNotificationCategory.status,
        ),
      ),
      payload: jsonEncode(notice.target.toJson()),
    );
  }

  @override
  Future<void> cancel(int id) => plugin.cancel(id: id);
  Future<void> openSettings() async {
    await plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.openAppNotificationSettings();
  }

  @override
  Future<void> setKeepConnected(bool enabled) async {
    if (Platform.isAndroid) {
      await _connection.invokeMethod<void>('setEnabled', enabled);
    }
  }
}
