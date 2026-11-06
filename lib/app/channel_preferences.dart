import 'package:shared_preferences/shared_preferences.dart';

import '../core/domain/signaling_service.dart';

/// Read once at startup; saving does not switch any live session.
class ChannelPreferences {
  static const webRtcKey = 'gateway_webrtc_enabled_v1';
  static const signalingServiceKey = 'gateway_signaling_service_v1';

  static Future<String?> loadSignalingService() async =>
      normalizeSignalingService(
        (await SharedPreferences.getInstance()).getString(
              signalingServiceKey,
            ) ??
            '',
      );

  static Future<void> saveSignalingService(String? address) async {
    final normalized = normalizeSignalingService(address ?? '');
    final preferences = await SharedPreferences.getInstance();
    final saved = normalized == null
        ? await preferences.remove(signalingServiceKey)
        : await preferences.setString(signalingServiceKey, normalized);
    if (!saved) throw StateError('Unable to save signaling service');
  }

  static Future<bool> loadWebRtcEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(webRtcKey) ?? false;

  static Future<void> saveWebRtcEnabled(bool enabled) async {
    final saved = await (await SharedPreferences.getInstance()).setBool(
      webRtcKey,
      enabled,
    );
    if (!saved) throw StateError('Unable to save channel preference');
  }
}
