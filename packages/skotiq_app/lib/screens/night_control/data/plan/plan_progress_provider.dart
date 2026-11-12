// The Plan section: one row per filter with frames and integration, the
// plan's estimated length and when it should end.
//
// Integration is the accepted light frames' exposure per filter, summed the
// way the run dashboard's filter totals sum it, but from the session's rows
// as they arrive: the dashboard's per-session total is read once and only
// re-read on the dashboard's own refresh, so on Tonight it stayed at the
// value from the run's start.
// Frame counts are this session's light frames; planned counts come from the
// plan's exposure steps, loops included.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart';

import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../../night_control_contracts.dart';
import '../session/session_frames_provider.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';
import 'plan_steps_provider.dart' show nightPlanLagProvider;

/// The run dashboard's key for frames taken without a filter.
const String _unfiltered = 'Unfiltered';

String _filterKey(String? filter) =>
    filter == null || filter.isEmpty ? _unfiltered : filter;

final nightPlanProgressProvider = Provider<NightPlanVm?>((ref) {
  final tree = ref.watch(nightPlanTreeProvider);
  if (tree == null) return null;

  // Planned light frames per filter, in the order the plan first uses each.
  // A filter with any exposure under an open-ended loop has no planned count.
  final planned = <String, int>{};
  final openEnded = <String>{};
  void plan(String? filter, int count, int multiplier, bool open) {
    final key = _filterKey(filter);
    final frames = count * multiplier;
    planned.update(key, (sum) => sum + frames, ifAbsent: () => frames);
    if (open) openEnded.add(key);
  }

  for (final entry in tree.entries) {
    final node = entry.node;
    if (node is ExposureNode && node.frameType != FrameType.light) continue;
    for (final run in node.kind.captures(node)) {
      plan(run.filter, run.count, entry.multiplier, entry.openEnded);
    }
    // Looping until stopped, a Smart Exposure has no count and shoots each of
    // its filters until the target's window closes.
    if (node.capturesUntilStopped) {
      for (final filter in node.kind.filtersOf(node)) {
        plan(filter, 0, entry.multiplier, true);
      }
    }
  }

  final phase = ref.watch(nightRunPhaseProvider);
  final totals = ref.watch(runDashboardFilterTotalsProvider);

  // Frames count only once a run has taken them; before a run starts the
  // session list may still hold the previous one, and the true count is none.
  final done = <String, int>{for (final key in planned.keys) key: 0};
  if (phase.isRunLive || phase == NightRunPhase.finished) {
    final terminal = ref.watch(shownTerminalRunResultProvider);
    // A linked client counts the run's session rows: the frame list below is
    // what this app saw arrive, and a client that joined after the run
    // started saw none of the frames before it.
    final sessionRows = terminal?.isCalibration == true ||
        ref.watch(backendProvider).remoteHost != null;
    final frames = sessionRows
        ? ref.watch(nightRunLightRowsProvider).map(capturedImageFromDbRow)
        : ref.watch(recentSessionFramesProvider);
    // This launch's frame list runs across runs; only this run's count.
    final startedAt = sessionRows ? null : ref.watch(runStartedAtProvider);
    final since = startedAt?.subtract(const Duration(seconds: 5));
    for (final frame in frames) {
      if (frame.settings.frameType != FrameType.light) continue;
      if (since != null && frame.capturedAt.isBefore(since)) continue;
      final key = _filterKey(frame.settings.filter);
      done.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  // A run continued from its checkpoint, ready or under way, already has the
  // frames its steps took before it.
  if (phase.isRunLive ||
      phase == NightRunPhase.finished ||
      ref.watch(restoredCheckpointProvider) != null) {
    final before = ref.watch(framesDoneBeforeRunProvider);
    for (final entry in tree.entries) {
      final node = entry.node;
      if (node is! ExposureNode || node.frameType != FrameType.light) continue;
      final frames = before[node.id];
      if (frames == null) continue;
      done.update(
        _filterKey(node.filter),
        (count) => count + frames,
        ifAbsent: () => frames,
      );
    }
  }

  Duration secs(double s) => Duration(milliseconds: (s * 1000).round());

  final acceptedSecs = <String, double>{};
  if (phase.isRunLive || phase == NightRunPhase.finished) {
    for (final row in ref.watch(nightRunLightRowsProvider)) {
      if (!row.isAccepted) continue;
      acceptedSecs.update(
        _filterKey(row.filter),
        (sum) => sum + row.exposureDuration,
        ifAbsent: () => row.exposureDuration,
      );
    }
  }

  // A filter with no accepted frame yet has integrated nothing.
  Duration accepted(String key) {
    final s = acceptedSecs[key];
    return s == null ? Duration.zero : secs(s);
  }

  final rows = <PlanFilterRowVm>[
    for (final key in planned.keys)
      PlanFilterRowVm(
        filter: key,
        framesDone: done[key]!,
        framesPlanned: openEnded.contains(key) ? null : planned[key],
        integrated: accepted(key),
        isCurrent: phase.isRunLive && totals.inFlightFilter == key,
      ),
  ];
  final integrated = rows.fold<Duration>(
    Duration.zero,
    (sum, row) => sum + row.integrated,
  );

  final timing = ref.watch(nightPlanTimingProvider);
  final clock = ref.watch(clockProvider);
  // No fixed length: a loop runs until a condition, or a block runs until it
  // is stopped and there is no site to bound it by its target's window.
  final planOpenEnded = tree.openEnded || timing?.openEnded == true;
  DateTime? eta;
  if (phase.isRunLive) {
    // The executor's remaining time is frames left times the average frame,
    // and a block looping until its window closes has no frames left to
    // count; the plan's estimate bounds it by the window instead.
    final remaining = tree.loopsUntilWindowEnds
        ? null
        : ref.watch(
            sequenceProgressProvider.select((p) => p.estimatedRemainingSecs),
          );
    if (remaining != null) {
      eta = ref.watch(nightNowProvider).add(secs(remaining));
    } else if (!planOpenEnded) {
      // The plan's estimate runs from the start; a run behind it ends later.
      eta = timing?.end.add(ref.watch(nightPlanLagProvider));
    }
  } else if (phase != NightRunPhase.finished && !planOpenEnded) {
    eta = timing?.end;
  }

  return NightPlanVm(
    rows: rows,
    integrated: integrated,
    openEnded: planOpenEnded,
    planned: planOpenEnded ? null : timing?.total,
    eta: eta == null ? null : clock.toNightClock(eta),
  );
});
