// "Start at dark": a timer in this app process that starts the loaded run at
// astronomical dark.
//
// On the imaging host it lives only as long as the app does: a restart clears
// it, and the screen says the app must stay open. A remote client holds no
// timer: the host keeps the schedule, and the client mirrors it.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../services/observing_site.dart';

/// Tonight's astronomical dark (end of evening twilight) as a UTC instant;
/// null without a site or when the sun never gets that low.
final nightAstroDarkProvider = Provider<DateTime?>((ref) {
  return ref.watch(siteTwilightTimesProvider)?.astronomicalDusk?.toUtc();
});

/// The note an armed start carries: on the imaging host the app must stay
/// open; on a client the host starts the run whatever this computer does.
final armedStartNoteKeyProvider = Provider<String>(
  (ref) => ref.watch(backendProvider).remoteHost != null
      ? 'nightActArmedOnHost'
      : 'nightActArmedKeepOpen',
);

/// When the armed start fires (a UTC instant), or null when not armed.
final nightArmedStartProvider =
    NotifierProvider<ArmedStartController, DateTime?>(
  ArmedStartController.new,
);

class ArmedStartController extends Notifier<DateTime?> {
  Timer? _timer;

  @override
  DateTime? build() {
    ref.onDispose(_cancelTimer);
    // A client shows the host's schedule; arming and canceling go to the host
    // (see NightActionController).
    if (ref.watch(backendProvider).remoteHost != null) {
      return ref.watch(hostScheduledStartProvider);
    }
    // A run started some other way (the header's Start, a remote client)
    // makes the armed start moot; leaving it armed would fire a second start
    // into a finished run later.
    ref.listen<SequenceExecutionState>(sequenceExecutionStateProvider,
        (previous, next) {
      if (state != null && next.isBusy) disarm();
    });
    return null;
  }

  /// Arms [fire] to run once at [at]. Replaces an earlier arming.
  void arm(DateTime at, Future<void> Function() fire) {
    _cancelTimer();
    final delay = at.difference(DateTime.now().toUtc());
    state = at.toUtc();
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      state = null;
      unawaited(fire());
    });
  }

  void disarm() {
    _cancelTimer();
    state = null;
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }
}
