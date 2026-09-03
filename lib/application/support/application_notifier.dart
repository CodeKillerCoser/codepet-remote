typedef ApplicationListener = void Function();

/// Minimal observable primitive for application services.
///
/// Keeping this in pure Dart prevents application state from depending on a
/// particular presentation framework.
abstract class ApplicationNotifier {
  final Set<ApplicationListener> _listeners = {};
  bool _notifierDisposed = false;

  void addListener(ApplicationListener listener) {
    if (!_notifierDisposed) _listeners.add(listener);
  }

  void removeListener(ApplicationListener listener) {
    _listeners.remove(listener);
  }

  void notifyApplicationListeners() {
    if (_notifierDisposed) return;
    for (final listener in _listeners.toList(growable: false)) {
      listener();
    }
  }

  void disposeNotifier() {
    _notifierDisposed = true;
    _listeners.clear();
  }

  void dispose() => disposeNotifier();
}
