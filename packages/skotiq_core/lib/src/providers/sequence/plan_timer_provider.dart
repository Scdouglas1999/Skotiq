import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/plan_timer.dart';
import '../../services/sequence_time_estimator.dart';
import '../sequence_provider.dart' show currentSequenceProvider;
import '../settings_provider.dart'
    show appObserverLocationProvider, appSettingsProvider;
import 'plan_run_end.dart';
import 'sequencer_defaults.dart' show sequencerOverheadConfigProvider;

/// The [PlanTimer] for this rig's settings: the Sequencer's overhead model,
/// the site, "Park before dawn", the autofocus cadence the executor adds and
/// the horizon.
final planTimerProvider = Provider<PlanTimer>((ref) {
  final site = ref.watch(appObserverLocationProvider);
  final s = ref.watch(
    appSettingsProvider.select((async) {
      final settings = async.valueOrNull;
      return (
        parkBeforeDawn: settings?.parkBeforeDawn ?? true,
        autoFocusOnFilterChange: settings?.autoFocusOnFilterChange ?? false,
        autoFocusEveryMinutes: settings?.autoFocusEveryMinutes ?? 0,
        horizon: settings?.effectiveHorizonDeg ?? 20.0,
      );
    }),
  );
  return PlanTimer(
    estimator: SequenceTimeEstimator(
      overhead: ref.watch(sequencerOverheadConfigProvider),
    ),
    site: site == null
        ? null
        : (latitude: site.latitude, longitude: site.longitude),
    runEndsBy: (start) => planRunEndsBy(
      parkBeforeDawn: s.parkBeforeDawn,
      latitude: site?.latitude,
      longitude: site?.longitude,
      now: start,
    ),
    autoFocusOnFilterChange: s.autoFocusOnFilterChange,
    autoFocusEveryMinutes: s.autoFocusEveryMinutes,
    minAltitude: s.horizon,
  );
});

/// The open sequence timed from when it last changed, or null with none open.
final currentPlanTimingProvider = Provider<PlanTiming?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;
  return ref.watch(planTimerProvider).time(sequence, DateTime.now());
});
