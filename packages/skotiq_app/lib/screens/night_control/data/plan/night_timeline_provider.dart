// The night strip under the header: sunset to sunrise, astronomical dark, a
// now marker and one window per target ("M74 → 03:40"). Window times are the
// estimator's unless this session's events recorded both ends.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../../dashboard/widgets/tonight/tonight_night.dart';
import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';

/// One target's slot in the plan. Instants, not operator-clock times.
class NightTargetWindow {
  const NightTargetWindow({
    required this.target,
    required this.start,
    required this.end,
    required this.estimated,
    required this.state,
  });

  final TargetHeaderNode target;
  final DateTime start;
  final DateTime end;

  /// False only when this session recorded both the start and the end.
  final bool estimated;

  final TimelineWindowState state;
}

/// Each target's window, in the order the run reaches them. Empty with no
/// plan or no target headers.
///
/// A window runs from the target's first estimated step to wherever the
/// estimate goes next, so a count loop inside the target (whose body the
/// estimator lists once) still gets its full length.
final nightTargetWindowsProvider = Provider<List<NightTargetWindow>>((ref) {
  final tree = ref.watch(nightPlanTreeProvider);
  final timing = ref.watch(nightPlanTimingProvider);
  if (tree == null || timing == null || tree.targets.isEmpty) {
    return const <NightTargetWindow>[];
  }

  final first = <String, int>{};
  final last = <String, int>{};
  final timings = timing.timings;
  for (var i = 0; i < timings.length; i++) {
    final targetId = timings[i].targetHeaderId;
    if (targetId == null) continue;
    first.putIfAbsent(targetId, () => i);
    last[targetId] = i;
  }

  final phase = ref.watch(nightRunPhaseProvider);
  final hasRun = phase.isRunLive || phase == NightRunPhase.finished;
  final statuses = hasRun
      ? ref.watch(sequenceProgressProvider.select((p) => p.nodeStatuses))
      : const <String, NodeStatus>{};
  final activeTarget =
      phase.isRunLive ? ref.watch(runDashboardActiveTargetProvider) : null;
  final recorded = ref.watch(nightNodeEventTimesProvider);

  final windows = <NightTargetWindow>[];
  for (final target in tree.targets) {
    final from = first[target.id];
    final to = last[target.id];
    if (from == null || to == null) continue;

    var estimatedEnd =
        to + 1 < timings.length ? timings[to + 1].estimatedStart : timing.end;
    if (estimatedEnd.isBefore(timings[to].estimatedEnd)) {
      estimatedEnd = timings[to].estimatedEnd;
    }

    final state = switch (statuses[target.id]) {
      NodeStatus.success ||
      NodeStatus.failure ||
      NodeStatus.skipped ||
      NodeStatus.cancelled =>
        TimelineWindowState.done,
      NodeStatus.running => TimelineWindowState.active,
      NodeStatus.pending || null => activeTarget?.id == target.id
          ? TimelineWindowState.active
          : TimelineWindowState.planned,
    };

    final estimatedStart = timings[from].estimatedStart;
    final startedAt = hasRun ? recorded.started[target.id] : null;
    final endedAt = state == TimelineWindowState.done
        ? recorded.completed[target.id]
        : null;
    // A target that really started late or early keeps its estimated length
    // from the recorded start, rather than ending before it began.
    final projectedEnd = startedAt == null
        ? estimatedEnd
        : startedAt.add(estimatedEnd.difference(estimatedStart));
    windows.add(
      NightTargetWindow(
        target: target,
        start: startedAt ?? estimatedStart,
        end: endedAt ?? projectedEnd,
        estimated: startedAt == null || endedAt == null,
        state: state,
      ),
    );
  }
  return windows;
});

final nightTimelineProvider = Provider<NightTimelineVm?>((ref) {
  final night = ref.watch(tonightNightProvider);
  if (night == null) return null;
  final clock = ref.watch(clockProvider);
  final windows = ref.watch(nightTargetWindowsProvider);

  return NightTimelineVm(
    sunset: night.sunset,
    sunrise: night.sunrise,
    now: clock.toNightClock(ref.watch(nightNowProvider)),
    astroDark: night.astroDark,
    astroDawn: night.astroDawn,
    windows: <TimelineWindowVm>[
      for (final window in windows)
        TimelineWindowVm(
          name: window.target.displayName,
          start: clock.toNightClock(window.start),
          end: clock.toNightClock(window.end),
          estimated: window.estimated,
          state: window.state,
        ),
    ],
  );
});
