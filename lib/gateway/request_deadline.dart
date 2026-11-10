/// Acquisition can restart a runtime and resume a native conversation. The Host
/// allows 45 seconds; conversation.resume additionally loads history (10 seconds).
/// Keep an outer transport margin, while ordinary calls still fail in 30 seconds.
Duration gatewayRequestDeadline(
  Object? method, {
  Duration ordinary = const Duration(seconds: 30),
}) => switch (method) {
  'conversation.acquireInteraction' ||
  'conversation.resume' => const Duration(seconds: 75),
  _ => ordinary,
};
