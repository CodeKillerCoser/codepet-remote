import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../diagnostics/app_log.dart';

/// External trigger adapter. No selection/retry policy and no route mutation.
final class ConnectionEnvironmentObserver with WidgetsBindingObserver {
  ConnectionEnvironmentObserver(this.onChanged) {
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _subscription = const EventChannel('com.codepet.remote/network_changes')
          .receiveBroadcastStream()
          .listen(
            (_) => _changed('network'),
            onError: (Object error) {
              if (error is! MissingPluginException) {
                _log.warning(
                  'Network observer unavailable type=${error.runtimeType}',
                );
              }
            },
          );
    }
  }
  final void Function(bool optimize) onChanged;
  bool _foreground = true;
  final _log = AppLog.named('connection.environment');
  StreamSubscription<dynamic>? _subscription;
  Timer? _debounce;
  void _changed(String reason) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _log.info('Connection input changed source=$reason');
      onChanged(_foreground);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _changed(_foreground ? 'foreground' : 'background');
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    unawaited(_subscription?.cancel());
  }
}
