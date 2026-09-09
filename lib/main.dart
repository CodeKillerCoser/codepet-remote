import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app/codepet_remote_app.dart';
import 'app/channel_preferences.dart';
import 'diagnostics/app_log.dart';

Future<void> main() async {
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await AppLog.initialize();
    final log = AppLog.named('uncaught');
    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      log.severe(
        'Uncaught Flutter framework error',
        error: details.exception,
        stackTrace: details.stack,
      );
    };
    PlatformDispatcher.instance.onError = (error, stackTrace) {
      log.severe(
        'Uncaught platform dispatcher error',
        error: error,
        stackTrace: stackTrace,
      );
      return true;
    };
    final webRtcEnabled = await ChannelPreferences.loadWebRtcEnabled();
    runApp(CodePetRemoteApp(webRtcEnabled: webRtcEnabled));
  }, (error, stackTrace) {
    AppLog.named('uncaught').severe(
      'Uncaught asynchronous error',
      error: error,
      stackTrace: stackTrace,
    );
  });
}
