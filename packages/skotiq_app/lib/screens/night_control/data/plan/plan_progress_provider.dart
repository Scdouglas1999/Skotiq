// The Plan section: one row per filter with frames and integration, the
// plan's estimated length and when it should end.
//
// Integration is the run dashboard's accepted total per filter
// (`runDashboardFilterTotalsProvider`), so the two screens cannot disagree.
// Frame counts are this session's light frames; planned counts come from the
// plan's exposure steps, loops included.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:skotiq_core/skotiq_core.dart' hide TwilightTimes;

import '../../../sequencer/widgets/run_dashboard/run_dashboard_providers.dart';
import '../../night_control_contracts.dart';
import 'night_plan_inputs.dart';
import 'night_run_phase_provider.dart';

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
  for (final entry in tree.entries) {
    final node = entry.node;
    if (node is! ExposureNode || node.frameType != FrameType.light) continue;
    final key = _filterKey(node.filter);
    final frames = node.count * entry.multiplier;
    planned.update(key, (sum) => sum + frames, ifAbsent: () => frames);
    if (entry.openEnded) openEnded.add(key);
  }
  if (planned.isEmpty) return null;

  final phase = ref.watch(nightRunPhaseProvider);
  final totals = ref.watch(runDashboardFilterTotalsProvider);

  // Frames count only once a run has taken them; before a run starts the
  // session list may still hold the previous one, and the true count is none.
  final done = <String, int>{for (final key in planned.keys) key: 0};
  if (phase.isRunLive || phase == NightRunPhase.finished) {
    for (final frame in ref.watch(recentSessionFramesProvider)) {
      if (frame.settings.frameType != FrameType.light) continue;
      final key = _filterKey(frame.settings.filter);
      done.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
  }

  Duration secs(double s) => Duration(milliseconds: (s * 1000).round());

  // A filter with no accepted frame yet has integrated nothing.
  Duration accepted(String key) {
    final s = totals.integrationSecs[key];
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
  DateTime? eta;
  if (phase.isRunLive) {
    final remaining = ref.watch(
      sequenceProgressProvider.select((p) => p.estimatedRemainingSecs),
    );
    if (remaining != null) {
      eta = ref.watch(nightNowProvider).add(secs(remaining));
    } else if (!tree.openEnded) {
      eta = timing?.end;
    }
  } else if (phase != NightRunPhase.finished && !tree.openEnded) {
    eta = timing?.end;
  }

  return NightPlanVm(
    rows: rows,
    integrated: integrated,
    planned: tree.openEnded ? null : timing?.total,
    eta: eta == null ? null : clock.toNightClock(eta),
  );
});
