abstract interface class ApplicationLog {
  void fine(String message);

  void info(String message);

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
