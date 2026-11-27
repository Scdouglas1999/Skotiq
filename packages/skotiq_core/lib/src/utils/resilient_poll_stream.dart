import 'dart:async';

import 'poll_pace.dart';

/// A failure that asking again cannot change, such as the refusal of a host
/// that refuses every call. A poll that meets one stops asking.
abstract interface class StandingRefusal implements Exception {}

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
///
/// The wait between fetches is [interval] at the device's [PollPace].
///
/// An event on [refresh] fetches now instead of waiting out the interval; one
/// that arrives during a fetch runs another fetch as soon as that one ends,
/// because the in-flight answer may predate whatever prompted the refresh.
///
/// A [StandingRefusal] ends the polling: it is reported like any other error
/// and nothing is fetched after it, on the timer or on [refresh].
Stream<T> resilientDistinctPoll<T>({
  required Future<T> Function() fetch,
  required bool Function(T previous, T next) unchanged,
  required Duration interval,
  void Function(Object error, StackTrace stackTrace)? onRetainedError,
  Stream<void>? refresh,
}) {
  late T last;
  var hasLast = false;
  var stopped = false;
  var refused = false;
  var paused = false;
  var polling = false;
  var refreshQueued = false;
  Timer? timer;
  StreamSubscription<void>? refreshSubscription;
  late final StreamController<T> controller;
  late final Future<void> Function() poll;

  void scheduleNext() {
    if (refused) return;
    if (stopped || paused || polling || (timer?.isActive ?? false)) return;
    timer = Timer(PollPace.stretch(interval), () {
      timer = null;
      unawaited(poll());
    });
  }

  poll = () async {
    if (stopped || refused || paused || polling) return;
    polling = true;
    try {
      final next = await fetch();
      if (!stopped && (!hasLast || !unchanged(last, next))) {
        last = next;
        hasLast = true;
        controller.add(next);
      }
    } catch (error, stackTrace) {
      if (error is StandingRefusal) refused = true;
      if (!stopped && !hasLast) {
        controller.addError(error, stackTrace);
      } else if (!stopped) {
        onRetainedError?.call(error, stackTrace);
      }
    } finally {
      polling = false;
      if (refreshQueued && !stopped && !paused) {
        refreshQueued = false;
        unawaited(poll());
      } else {
        scheduleNext();
      }
    }
  };

  void refreshNow() {
    if (stopped || refused) return;
    if (polling || paused) {
      refreshQueued = true;
      return;
    }
    timer?.cancel();
    timer = null;
    unawaited(poll());
  }

  controller = StreamController<T>(
    onListen: () {
      refreshSubscription = refresh?.listen((_) => refreshNow());
      unawaited(poll());
    },
    onPause: () {
      paused = true;
      timer?.cancel();
    },
    onResume: () {
      paused = false;
      if (refreshQueued) {
        refreshQueued = false;
        unawaited(poll());
      } else {
        scheduleNext();
      }
    },
    onCancel: () {
      stopped = true;
      timer?.cancel();
      return refreshSubscription?.cancel();
    },
  );
  return controller.stream;
}
