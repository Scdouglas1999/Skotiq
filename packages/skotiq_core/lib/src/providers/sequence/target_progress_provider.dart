import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/sequence/sequence_models.dart';
import '../sequence_provider.dart'
    show currentSequenceProvider, sequenceProgressProvider;

/// Snapshot of execution progress *aggregated across a single
/// [TargetHeaderNode]*.
///
/// The tree shows a "8/24 frames • 32m / 96m" status under each target row
/// while a sequence is running. The math is non-trivial (walk the subtree
/// once, sum planned vs completed exposures) and is also used by the
/// target-card progress bar, so it lives in a derived provider that can be
/// watched in multiple places without recomputing per rebuild.
class TargetExecutionProgress {
  /// Planned exposure count under this target, with loop multipliers applied
  /// (so it matches `Sequence.totalExposures`, the toolbar frame counter and
  /// the card's own idle plan line).
  final int totalFrames;

  /// Completed exposures attributed to this target.
  ///
  /// Comes from cross-referencing
  /// [SequenceProgress.completedExposures] against per-node statuses:
  /// every [ExposureNode] under this target that is `success` contributes
  /// its `count`; the currently-running exposure contributes the partial
  /// frame count derived from `nodeProgressPercent`.
  final int completedFrames;

  /// Planned integration time under this target, in seconds.
  final double totalIntegrationSecs;

  /// Completed integration time under this target, in seconds.
  /// Same accounting rule as [completedFrames] but in seconds.
  final double completedIntegrationSecs;

  /// True when this target's completion cannot be derived at all.
  ///
  /// [completedFrames] is normally reconstructed from per-node statuses, but a
  /// loop RESETS its children on every pass (see `loop_node.rs`), so under a
  /// loop those statuses only describe the CURRENT pass and nothing on the
  /// wire carries the pass index (`InstructionProgress` is node_id /
  /// instruction / progress_percent / detail only).
  ///
  /// A looped target is not automatically unknowable: when every frame the run
  /// plans sits under this one target, the loop-correct run-level frame counter
  /// describes it exactly (see the attribution block in the provider). What
  /// stays unknown is a repeat with no true denominator (forever / until-time /
  /// until-altitude), and a repeat whose frames cannot be told apart from
  /// another target's.
  ///
  /// Callers must render [totalFrames] (which is true) and not a completion
  /// ratio when this is set.
  final bool completionUnknown;

  const TargetExecutionProgress({
    required this.totalFrames,
    required this.completedFrames,
    required this.totalIntegrationSecs,
    required this.completedIntegrationSecs,
    this.completionUnknown = false,
  });

  static const empty = TargetExecutionProgress(
    totalFrames: 0,
    completedFrames: 0,
    totalIntegrationSecs: 0,
    completedIntegrationSecs: 0,
  );

  /// Fraction of frames completed, in [0.0, 1.0]. Returns 0 when no frames
  /// are planned to avoid a divide-by-zero (the UI also hides the bar in
  /// that case), and when [completionUnknown] — a per-pass count over a
  /// whole-run denominator is not a completion fraction, in either direction.
  double get fraction {
    if (totalFrames <= 0 || completionUnknown) return 0;
    return (completedFrames / totalFrames).clamp(0.0, 1.0);
  }

  bool get hasPlannedFrames => totalFrames > 0;

  /// True when [completedFrames] / [fraction] describe the whole run for this
  /// target and may be rendered as progress.
  bool get hasKnownCompletion => !completionUnknown;
}

/// Per-target progress, keyed by `TargetHeaderNode.id`.
///
/// Watches [currentSequenceProvider] (to know the planned shape) and
/// [sequenceProgressProvider] (to know what's been done). Returning the
/// empty snapshot when the target is missing keeps the call-site
/// branch-free.
final targetExecutionProgressProvider =
    Provider.family<TargetExecutionProgress, String>((ref, targetNodeId) {
      final sequence = ref.watch(currentSequenceProvider);
      final progress = ref.watch(sequenceProgressProvider);

      if (sequence == null) return TargetExecutionProgress.empty;
      final root = sequence.nodes[targetNodeId];
      if (root == null) return TargetExecutionProgress.empty;

      int totalFrames = 0;
      int completedFrames = 0;
      double totalIntegrationSecs = 0;
      double completedIntegrationSecs = 0;
      bool completionUnknown = false;
      // True once an exposure is found under a loop with no fixed iteration
      // count. For those, `totalFrames` is a ONE-PASS FLOOR, not a plan, so it
      // must never become the denominator of a completion ratio.
      bool hasUnboundedRepeat = false;

      // Defense in depth against import-malformed trees that contain cycles.
      final visited = <String>{targetNodeId};

      /// [mult] is how many times this subtree runs (count-loop repeats
      /// compounded), mirroring `Sequence._countExposures`. [repeats] is true
      /// once a loop that runs its body more than once is an ancestor;
      /// [unbounded] once one of those loops has no fixed iteration count.
      void visit(SequenceNode node, int mult, bool repeats, bool unbounded) {
        if (node is ExposureNode && node.isEnabled) {
          totalFrames += node.count * mult;
          totalIntegrationSecs += node.totalDurationSecs * mult;
          if (unbounded) hasUnboundedRepeat = true;

          if (repeats) {
            // Per-node statuses are reset by the loop on every pass, so they
            // cannot be scaled into a run total. Say so instead of dividing a
            // one-pass count by the whole-run plan.
            completionUnknown = true;
          } else {
            final status = progress.nodeStatuses[node.id];
            if (status == NodeStatus.success) {
              // Fully completed: every frame counts.
              completedFrames += node.count;
              completedIntegrationSecs += node.totalDurationSecs;
            } else if (status == NodeStatus.running) {
              // Partial: derive how many frames have finished within this node
              // from the per-node progress percent. The executor publishes
              // 0..100; clamp defensively because some backends round above
              // 100 on the final tick.
              final pct = (progress.nodeProgressPercent[node.id] ?? 0).clamp(
                0,
                100,
              );
              final partial = (node.count * pct / 100.0).floor();
              completedFrames += partial;
              completedIntegrationSecs += node.durationSecs * partial;
            }
            // pending / failure / skipped / cancelled contribute 0.
          }
        }

        var childMult = mult;
        var childRepeats = repeats;
        var childUnbounded = unbounded;
        if (node is LoopNode) {
          if (node.conditionType == LoopConditionType.count) {
            final iterations = node.repeatCount ?? 1;
            childMult = mult * iterations;
            if (iterations > 1) childRepeats = true;
          } else {
            // until-time / altitude / forever / while-dark: the body runs an
            // unknown number of times, so the planned total is a one-pass
            // floor and completion is not derivable.
            childRepeats = true;
            childUnbounded = true;
          }
        }

        for (final childId in node.childIds) {
          if (!visited.add(childId)) continue;
          final child = sequence.nodes[childId];
          if (child == null) continue;
          visit(child, childMult, childRepeats, childUnbounded);
        }
      }

      visit(root, 1, false, false);

      // A repeat defeats the per-node reconstruction above, but it does not
      // always make completion unknowable. When every frame the RUN plans sits
      // under this one target, the run-level counters describe this target
      // exactly — and `completedExposures` is the executor's absolute frame
      // index, advanced once per `ExposureCompleted`, so unlike a node status
      // it already counts loop passes and survives the loop's per-pass reset.
      //
      // Both guards are load-bearing and both fail CLOSED, leaving the honest
      // "N frames planned" rendering rather than a fabricated ratio:
      //   * `!hasUnboundedRepeat` — under a forever/until-time loop
      //     `totalFrames` is a one-pass FLOOR. Dividing the run counter by it
      //     would re-create the exact "1/1 done - 100%" defect this flag was
      //     added to kill, just sourced from the wire instead of node statuses.
      //   * the equality against the model's own total — any frame planned
      //     outside this target (a second target, a calibration block at the
      //     root, or a Smart/photometry node this walk does not count but
      //     `totalExposures` does) makes the run counter un-attributable.
      if (completionUnknown &&
          !hasUnboundedRepeat &&
          totalFrames > 0 &&
          totalFrames == sequence.totalExposures) {
        // Clamp: a plan edited mid-run can leave the counter past the total.
        completedFrames = progress.completedExposures.clamp(0, totalFrames);
        completedIntegrationSecs = progress.completedIntegrationSecs;
        completionUnknown = false;
      }

      return TargetExecutionProgress(
        totalFrames: totalFrames,
        completedFrames: completedFrames,
        totalIntegrationSecs: totalIntegrationSecs,
        completedIntegrationSecs: completedIntegrationSecs,
        completionUnknown: completionUnknown,
      );
    });
