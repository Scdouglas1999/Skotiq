import 'dart:async';

/// Repeatedly calls [fetch], emits the first successful value, and then emits
/// only values for which [unchanged] returns false.
///
/// An error before the first value is forwarded to listeners while polling
/// continues. After data exists, transient errors retain that data and are
/// reported through [onRetainedError]. Timers stop immediately when the last
/// listener cancels; an in-flight fetch is allowed to finish but its result is
/// discarded. A controller is used instead of an `async*` loop because a
/// distinct stream may go indefinitely without another `yield`, which prevents
/// an `async*` subscription's cancellation future from completing.
Stream<T> resilientDistinctPoll<T>({
  required Future<T> Function() fetch,
  required bool Function(T previous, T next) unchanged,
  required Duration interval,
  void Function(Object error, StackTrace stackTrace)? onRetainedError,
}) {
  late T last;
  var hasLast = false;
  var stopped = false;
  var paused = false;
  var polling = false;
  Timer? timer;
  late final StreamController<T> controller;
  late final Future<void> Function() poll;

  void scheduleNext() {
    if (stopped || paused || polling || (timer?.isActive ?? false)) return;
    timer = Timer(interval, () {
      timer = null;
      unawaited(poll());
    });
  }

  poll = () async {
    if (stopped || paused || polling) return;
    polling = true;
    try {
      final next = await fetch();
      if (!stopped && (!hasLast || !unchanged(last, next))) {
        last = next;
        hasLast = true;
        controller.add(next);
      }
    } catch (error, stackTrace) {
      if (!stopped && !hasLast) {
        controller.addError(error, stackTrace);
      } else if (!stopped) {
        onRetainedError?.call(error, stackTrace);
      }
    } finally {
      polling = false;
      scheduleNext();
    }
  };

  controller = StreamController<T>(
    onListen: () => unawaited(poll()),
    onPause: () {
      paused = true;
      timer?.cancel();
    },
    onResume: () {
      paused = false;
      scheduleNext();
    },
    onCancel: () {
      stopped = true;
      timer?.cancel();
    },
  );
  return controller.stream;
}
