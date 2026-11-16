import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart'
    show SequenceExecutionStateCapabilities;
import '../../services/plan_timer.dart';
import '../../services/sequence_time_estimator.dart';
import '../armed_start_provider.dart' show nightArmedStartProvider;
import '../clock_provider.dart' show ClockInstant, clockProvider;
import '../sequence_provider.dart' show currentSequenceProvider;
import '../session_provider.dart' show sessionStateProvider;
import '../settings_provider.dart'
    show
        appObserverLocationProvider,
        appSettingsProvider,
        autofocusSettingsProvider;
import '../scheduler_provider.dart' show altitudeFloorProvider;
import 'plan_run_end.dart';
import 'sequence_progress.dart' show sequenceExecutionStateProvider;
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
      floor: ref.watch(altitudeFloorProvider),
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
  );
});

/// When the loaded plan's estimate starts, where something fixes it: the
/// session's start while a run is live (so the steps already done keep their
/// places), the armed time when "Start at dark" is armed. Instant (UTC). Null
/// otherwise, when the plan starts now.
///
/// Tonight's plan and the Sequencer's timeline, durations and ETA column all
/// time the plan from here, so they give the same times.
final planStartProvider = Provider<DateTime?>((ref) {
  if (ref.watch(sequenceExecutionStateProvider).isBusy) {
    return ref.watch(sessionStateProvider.select((s) => s.startTime))?.toUtc();
  }
  return ref.watch(nightArmedStartProvider)?.toUtc();
});

/// The open sequence timed from [planStartProvider], or from the app clock's
/// now when the sequence last changed; null with none open.
final currentPlanTimingProvider = Provider<PlanTiming?>((ref) {
  final sequence = ref.watch(currentSequenceProvider);
  if (sequence == null) return null;
  final start =
      ref.watch(planStartProvider) ?? ref.watch(clockProvider).instant;
  return ref.watch(planTimerProvider).time(sequence, start);
});
