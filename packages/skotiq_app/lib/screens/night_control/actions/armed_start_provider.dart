// "Start at dark": a timer in this app process that starts the loaded run at
// astronomical dark.
//
// It lives only as long as the app does. A restart clears it, a headless host
// never sees it, and the screen says the app must stay open.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../services/observing_site.dart';

/// Tonight's astronomical dark (end of evening twilight) as a UTC instant;
/// null without a site or when the sun never gets that low.
final nightAstroDarkProvider = Provider<DateTime?>((ref) {
  return ref.watch(siteTwilightTimesProvider)?.astronomicalDusk?.toUtc();
});

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
