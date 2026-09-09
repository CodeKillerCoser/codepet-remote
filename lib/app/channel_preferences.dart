import 'package:shared_preferences/shared_preferences.dart';

/// Read once at startup; saving does not switch any live session.
class ChannelPreferences {
  static const webRtcKey = 'gateway_webrtc_enabled_v1';

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
