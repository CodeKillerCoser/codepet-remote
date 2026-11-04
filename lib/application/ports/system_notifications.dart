import '../../core/domain/notification.dart';

abstract interface class SystemNotifications {
  Future<bool> isAllowed();
  Future<bool> requestPermission();
  Future<void> show(RemoteNotice notice);
  Future<void> cancel(int id);
  Future<void> setKeepConnected(bool enabled);
}

abstract interface class NotificationStore {
  Future<Map<String, dynamic>> loadLedger();
  Future<void> saveLedger(Map<String, dynamic> ledger);
  Future<NotificationPreferences> loadPreferences();
  Future<void> savePreferences(NotificationPreferences preferences);
}
