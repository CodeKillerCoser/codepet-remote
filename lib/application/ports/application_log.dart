abstract interface class ApplicationLog {
  void fine(String message);

  void info(String message);

  void structured(String event, Map<String, Object?> fields);

  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });

  void severe(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  });
}

class NoopApplicationLog implements ApplicationLog {
  const NoopApplicationLog();

  @override
  void fine(String message) {}

  @override
  void info(String message) {}

  @override
  void structured(String event, Map<String, Object?> fields) {}

  @override
  void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {}

  @override
  void severe(
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {}
}
