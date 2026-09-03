import 'dart:async';
import 'dart:collection';

import '../../core/domain/models.dart';
import '../errors/application_failures.dart';

/// Buffers subscribed events while an application snapshot is loading, then
/// installs an exact cursor fence before delivering live updates.
class GatewayEventWindow {
  GatewayEventWindow._(this.startCursor, Stream<GatewayEvent> events) {
    _subscription = events.listen(
      (event) {
        if (_onEvent == null) {
          _buffer.add(event);
        } else {
          _deliver(event);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (_onEvent == null) {
          _errors.add((error, stack));
        } else {
          _onError?.call(error, stack);
        }
      },
    );
  }

  factory GatewayEventWindow.forStream(
    String? startCursor,
    Stream<GatewayEvent> events,
  ) => GatewayEventWindow._(startCursor, events);

  final String? startCursor;
  final List<GatewayEvent> _buffer = [];
  final List<(Object, StackTrace)> _errors = [];
  final _BoundedCursorSet _delivered = _BoundedCursorSet();
  late final StreamSubscription<GatewayEvent> _subscription;
  void Function(GatewayEvent)? _onEvent;
  void Function(Object, StackTrace)? _onError;

  void install({
    required String baselineCursor,
    required String snapshotCursor,
    required void Function(GatewayEvent) onEvent,
    void Function(Object, StackTrace)? onError,
  }) {
    if (_onEvent != null) {
      throw StateError('Gateway event window is already installed');
    }
    if (_errors.isNotEmpty) {
      Error.throwWithStackTrace(_errors.first.$1, _errors.first.$2);
    }
    var boundary = -1;
    for (var index = 0; index < _buffer.length; index++) {
      if (_buffer[index].eventCursor == snapshotCursor) boundary = index;
    }
    if (snapshotCursor != baselineCursor && boundary == -1) {
      throw const GatewayCursorGapException(
        'Snapshot cursor was not found in the subscribed event window',
      );
    }
    _onEvent = onEvent;
    _onError = onError;
    final suffix = _buffer.skip(boundary + 1).toList(growable: false);
    _buffer.clear();
    for (final event in suffix) {
      _deliver(event);
    }
  }

  void _deliver(GatewayEvent event) {
    if (_delivered.add(event.eventCursor)) _onEvent?.call(event);
  }

  Future<void> close() => _subscription.cancel();
}

class _BoundedCursorSet {
  static const capacity = 512;
  final Set<String> _values = {};
  final Queue<String> _arrivalOrder = Queue<String>();

  bool add(String cursor) {
    if (!_values.add(cursor)) return false;
    _arrivalOrder.addLast(cursor);
    while (_arrivalOrder.length > capacity) {
      _values.remove(_arrivalOrder.removeFirst());
    }
    return true;
  }
}
