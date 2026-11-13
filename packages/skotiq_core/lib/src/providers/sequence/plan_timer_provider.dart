import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/plan_timer.dart';
import '../../services/sequence_time_estimator.dart';
import '../sequence_provider.dart' show currentSequenceProvider;
import '../settings_provider.dart'
    show
        appObserverLocationProvider,
        appSettingsProvider,
        autofocusSettingsProvider;
import '../scheduler_provider.dart' show altitudeFloorProvider;
import 'plan_run_end.dart';
import 'sequencer_defaults.dart' show sequencerOverheadConfigProvider;

/// The [PlanTimer] for this rig's settings: the Sequencer's overhead model,
/// the Autofocus settings, the site, "Park before dawn", the autofocus cadence
/// the executor adds and the site's altitude floor.
final planTimerProvider = Provider<PlanTimer>((ref) {
  final site = ref.watch(appObserverLocationProvider);
  final s = ref.watch(
    appSettingsProvider.select((async) {
      final settings = async.valueOrNull;
      return (
        parkBeforeDawn: settings?.parkBeforeDawn ?? true,
        autoFocusOnFilterChange: settings?.autoFocusOnFilterChange ?? false,
        autoFocusEveryMinutes: settings?.autoFocusEveryMinutes ?? 0,
      );
    }),
  );
  return PlanTimer(
    estimator: SequenceTimeEstimator(
      overhead: ref.watch(sequencerOverheadConfigProvider),
      autofocus: ref.watch(autofocusSettingsProvider),
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
    // The estimator holds one number for the night: the lowest the floor
    // goes, so no target is timed out for a direction it may not be in.
    minAltitude: ref.watch(altitudeFloorProvider).lowestDeg,
  );
});

/// The open sequence timed from when it last changed, or null with none open.
final currentPlanTimingProvider = Provider<PlanTiming?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;
  return ref.watch(planTimerProvider).time(sequence, DateTime.now());
});
