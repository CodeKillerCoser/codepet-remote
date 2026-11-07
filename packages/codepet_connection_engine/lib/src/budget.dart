import 'dart:async';

import 'contracts.dart';

/// Shared priority budget, FIFO within each priority. Cancelled waiters are removed, and permits are retained
/// until native preparation/cleanup really finishes (including late results).
final class CandidateBudget {
  CandidateBudget({this.limit = 8}) {
    if (limit < 1) throw ArgumentError('limit');
  }
  final int limit;
  int _used = 0;
  final _queue = <_Waiter>[];
  int get used => _used;
  int get waiting => _queue.length;
  Future<BudgetLease> acquire(
    Cancellation cancellation, {
    int priority = 0,
  }) async {
    cancellation.check();
    final waiter = _Waiter(priority);
    final ahead = _queue.indexWhere((entry) => entry.priority > priority);
    if (ahead < 0) {
      _queue.add(waiter);
    } else {
      _queue.insert(ahead, waiter);
    }
    _drain();
    // Race without registering a permanently retained callback on a long-lived
    // token: every candidate token is cancelled on retirement/activation.
    final result = await Future.any<BudgetLease?>([
      waiter.result.future,
      cancellation.whenCancelled.then((_) => null),
    ]);
    if (result == null || cancellation.isCancelled) {
      if (_queue.remove(waiter)) {
        waiter.result.completeError(const ConnectionFailure('cancelled'));
      } else {
        (result ?? await waiter.result.future).release();
      }
      throw const ConnectionFailure('cancelled');
    }
    return result;
  }

  void _drain() {
    while (_used < limit && _queue.isNotEmpty) {
      _used++;
      _queue
          .removeAt(0)
          .result
          .complete(
            BudgetLease._(() {
              _used--;
              _drain();
            }),
          );
    }
  }
}

final class BudgetLease {
  BudgetLease._(this._release);
  final void Function() _release;
  bool _released = false;
  void release() {
    if (!_released) {
      _released = true;
      _release();
    }
  }
}

final class _Waiter {
  _Waiter(this.priority);
  final int priority;
  final result = Completer<BudgetLease>();
}
