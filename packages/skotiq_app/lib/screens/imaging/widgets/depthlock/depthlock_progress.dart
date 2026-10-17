import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'depthlock_presentation.dart';

/// How far a goal has got, in one element.
///
/// The bar is the **conservative** score against the threshold, because that
/// is the comparison the executor makes; drawing the raw score would show a
/// goal apparently past its line while the run kept going.
///
/// Before the estimator will say anything there is no score to draw, so the
/// bar becomes the exposure count against the minimum instead — a goal on its
/// eighth frame is making progress, and a bar pinned at zero for the first
/// four hours of a night says the opposite.
///
/// There is deliberately no forecast. How long a goal takes depends on the
/// sky, the target's altitude and how many nights the operator gives it; a
/// number here would be a guess wearing a countdown's clothes.
class DepthLockProgress extends StatelessWidget {
  const DepthLockProgress(
      {super.key, required this.goal, this.compact = false});

  final DepthLockGoal goal;

  /// The list row's variant: bar and one line, no labelled end-points.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final report = goal.report;
    final DepthLockState state = goal.state;
    final double threshold = goal.definition.measurement.threshold;
    final bool measuring = state != DepthLockState.insufficientEvidence;

    final double? conservative = report?.conservativeScore;
    final double value = measuring
        ? (threshold <= 0 || conservative == null
            ? 0.0
            : (conservative / threshold).clamp(0.0, 1.0))
        : (goal.evidenceFrames / kDepthLockMinimumEvidenceFrames).clamp(
            0.0,
            1.0,
          );

    final String leading = measuring
        ? 'S/N ${depthLockScore(conservative)}'
        : '${goal.evidenceFrames} of $kDepthLockMinimumEvidenceFrames '
            'exposures';
    final String trailing = measuring
        ? 'needs ${threshold.toStringAsFixed(1)}'
        : 'before measuring starts';
    // Before measuring starts the caption pair above already says how many
    // exposures are still owed; a third line saying it again is noise.
    final String? forecastLine = measuring ? depthLockForecastLine(goal) : null;
    final String? yieldLine = depthLockYieldLine(goal);
    final bool unreachable = report?.forecast?.reachable == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        // One accessible node for the pair: read apart, "5.2" and "6.0" are
        // two unattributed numbers.
        Semantics(
          label: measuring
              ? 'Conservative signal-to-noise ${depthLockScore(conservative)} of '
                  'threshold ${threshold.toStringAsFixed(1)}'
              : leading,
          child: SkotiqProgressBar(
            value: value,
            style: SkotiqProgressStyle.thin,
            state: _barState(state),
          ),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        // The two captions flow onto a second line in a narrow list row
        // rather than eating each other's ellipsis.
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: SkotiqTokens.spaceSm,
          runSpacing: 2,
          children: <Widget>[
            Text(
              leading,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textSecondary,
              ),
            ),
            Text(
              trailing,
              style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
              ),
            ),
          ],
        ),
        if (!compact &&
            state == DepthLockState.confirmationPending) ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            '${report?.confirmationFrames ?? 0} of '
            '$kDepthLockConfirmationFrames confirming exposures',
            style: SkotiqTypography.caption.copyWith(
              color: colors.warning,
            ),
          ),
        ],
        // What the goal is still expected to cost, in integration time rather
        // than clock time: the night it lands on depends on weather nobody
        // has, but the hours it needs are a property of the sky it has seen.
        if (forecastLine != null) ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            forecastLine,
            style: SkotiqTypography.caption.copyWith(
              color: unreachable ? colors.warning : colors.textSecondary,
            ),
          ),
        ],
        if (yieldLine != null) ...<Widget>[
          const SizedBox(height: SkotiqTokens.spaceXs),
          Text(
            yieldLine,
            style: SkotiqTypography.caption.copyWith(
              color: colors.textMuted,
            ),
          ),
        ],
      ],
    );
  }

  /// The bar takes the state's own colour so the element reads the same way
  /// as the chip beside it.
  SkotiqProgressState _barState(DepthLockState state) => switch (state) {
        DepthLockState.insufficientEvidence => SkotiqProgressState.paused,
        DepthLockState.collecting => SkotiqProgressState.normal,
        DepthLockState.confirmationPending => SkotiqProgressState.warning,
        DepthLockState.achieved => SkotiqProgressState.success,
        DepthLockState.unreliable => SkotiqProgressState.error,
      };
}
