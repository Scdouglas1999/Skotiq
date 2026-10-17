import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'focuser_backlash_text.dart';

/// The focuser backlash calibration wizard.
///
/// A focuser's gear train has a dead band: a move that reverses direction
/// spends the first N steps taking up slack before the optics move at all. The
/// app has never been able to MEASURE it, so the compensation setting ships at
/// 0 — and on 2026-09-14 that produced visibly donut-shaped stars after an
/// autofocus run whose curve looked near perfect, because the sweep sampled
/// every point moving UP and the final move arrived DOWNWARD.
///
/// The native routine scans focus twice, approaching every point from below and
/// then from above, fits both, and reports the gap between the two vertices.
/// This dialog is a thin view over [focuserBacklashCalibrationProvider]: it
/// never touches the focuser itself.
///
/// The three outcomes are all first class:
///   * **measured** — a figure, always shown WITH the position, temperature and
///     date it belongs to. On the owner's EAF the same focuser measured 105
///     steps near 6600 and 83 steps near 2500, so a bare number is a lie.
///   * **no measurable backlash** — a SUCCESSFUL measurement, and the right
///     answer for plenty of focusers. Never dressed as a failure.
///   * **refused** — the native side declined to publish a figure it could not
///     stand behind, with a written reason and remedy. A confident wrong number
///     is far worse than "I could not measure this", so the refusal gets a
///     dignified panel, not an error dialog.
class FocuserBacklashCalibrationDialog extends ConsumerWidget {
  const FocuserBacklashCalibrationDialog({super.key});

  /// Data key of the [PopScope] that blocks dismissal mid-run.
  static const String popGuardKey = 'backlash-wizard-pop-guard';

  /// Opens the wizard.
  ///
  /// The plan is loaded before the first frame so the intro panel can state the
  /// real travel and estimate rather than a placeholder, and the controller is
  /// reset on dismissal so the next open starts from a clean intro rather than
  /// a stale terminal state.
  static Future<void> show(BuildContext context) async {
    final container = ProviderScope.containerOf(context, listen: false);
    final notifier =
        container.read(focuserBacklashCalibrationProvider.notifier);
    // Not awaited: the dialog opens immediately on its own loading state and
    // follows the plan in reactively, rather than holding the operator on a
    // dead tap while the focuser is queried.
    unawaited(notifier.loadPlan());
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => const FocuserBacklashCalibrationDialog(),
    );
    notifier.reset();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(focuserBacklashCalibrationProvider);

    // Walking away mid-run leaves the focuser parked somewhere in the middle
    // of a two-direction sweep. PopScope covers the barrier and the back
    // gesture; the header close button pops the route directly and is gated
    // separately by `closeEnabled`. The one exit while scanning is Cancel,
    // which actually stops the run and returns the focuser.
    return PopScope(
      // Tagged so the mid-run dismissal guard can be asserted directly rather
      // than through the route's own PopScope, which looks identical.
      key: const ValueKey<String>(popGuardKey),
      canPop: !state.isRunning,
      child: SkotiqDialog(
        title: 'Measure focuser backlash',
        icon: LucideIcons.gitCompare,
        closeEnabled: !state.isRunning,
        width: 720,
        actions: _actionsFor(context, ref, state),
        child: _Body(state: state),
      ),
    );
  }

  List<Widget> _actionsFor(
    BuildContext context,
    WidgetRef ref,
    FocuserBacklashCalibrationState state,
  ) {
    final notifier = ref.read(focuserBacklashCalibrationProvider.notifier);
    switch (_surfaceFor(state)) {
      case _Surface.intro:
        return [
          SkotiqButton(
            label: 'Not now',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
          SkotiqButton(
            label: 'Measure backlash',
            icon: LucideIcons.play,
            // Disabled until the plan is in: the run needs a centre position
            // and travel limits read off the focuser, and starting without
            // them would move it blind.
            onPressed: state.plan == null ? null : () => notifier.run(),
            semanticsHint: state.plan == null
                ? 'Reading the focuser position and travel limits'
                : null,
          ),
        ];
      case _Surface.progress:
        return [
          SkotiqButton(
            label: 'Cancel',
            variant: ButtonVariant.secondary,
            icon: LucideIcons.x,
            onPressed: notifier.cancel,
          ),
        ];
      case _Surface.result:
        if (state.isSaved) {
          return [
            SkotiqButton(
              label: 'Done',
              onPressed: () => Navigator.of(context).pop(),
            ),
          ];
        }
        return [
          SkotiqButton(
            label: 'Re-run',
            variant: ButtonVariant.ghost,
            icon: LucideIcons.refreshCw,
            onPressed: () => notifier.run(),
          ),
          SkotiqButton(
            label: 'Discard',
            variant: ButtonVariant.secondary,
            icon: LucideIcons.trash2,
            onPressed: () {
              notifier.discard();
              Navigator.of(context).pop();
            },
          ),
          SkotiqButton(
            label: 'Save',
            icon: LucideIcons.save,
            onPressed: notifier.save,
          ),
        ];
      case _Surface.refusal:
      case _Surface.failure:
        return [
          SkotiqButton(
            label: 'Close',
            variant: ButtonVariant.ghost,
            onPressed: () => Navigator.of(context).pop(),
          ),
          SkotiqButton(
            label: 'Try again',
            icon: LucideIcons.refreshCw,
            onPressed: () => notifier.run(),
          ),
        ];
    }
  }
}

/// Which surface the wizard is showing.
///
/// Resolved once from the state and used by BOTH the body and the footer, so
/// the panel on screen and the buttons under it can never disagree — the shape
/// of bug where a cancelled run shows the intro above a "Try again / Close"
/// footer.
enum _Surface { intro, progress, result, refusal, failure }

_Surface _surfaceFor(FocuserBacklashCalibrationState state) {
  switch (state.phase) {
    case FocuserBacklashPhase.idle:
      return _Surface.intro;
    case FocuserBacklashPhase.scanningFromBelow:
    case FocuserBacklashPhase.scanningFromAbove:
    case FocuserBacklashPhase.analysing:
      return _Surface.progress;
    case FocuserBacklashPhase.complete:
      return _Surface.result;
    case FocuserBacklashPhase.refused:
      return _Surface.refusal;
    case FocuserBacklashPhase.failed:
      // A stop the operator asked for is not a failure, and an error panel
      // with nothing in it is worse than none: with no message to report, the
      // intro is the surface they can act on.
      return state.errorMessage == null ? _Surface.intro : _Surface.failure;
  }
}

/// Switches between the wizard surfaces. A separate widget so each surface
/// rebuilds against the watched state without re-running the dialog scaffold.
class _Body extends StatelessWidget {
  const _Body({required this.state});

  final FocuserBacklashCalibrationState state;

  @override
  Widget build(BuildContext context) {
    switch (_surfaceFor(state)) {
      case _Surface.intro:
        // `status` is empty on a fresh open and carries the last run's parting
        // line otherwise — above all a cancellation, which lands back here
        // ready to re-run. Shown verbatim so the operator is told the focuser
        // has been put back rather than left wondering.
        return _IntroPanel(plan: state.plan, note: state.status);
      case _Surface.progress:
        return _ProgressPanel(state: state);
      case _Surface.result:
        return _ResultPanel(state: state, result: state.result!);
      case _Surface.refusal:
        return _RefusalPanel(state: state, result: state.result!);
      case _Surface.failure:
        return _FailurePanel(state: state);
    }
  }
}

// Intro

class _IntroPanel extends StatelessWidget {
  const _IntroPanel({required this.plan, this.note = ''});

  final FocuserBacklashCalibrationPlan? plan;

  /// How the previous attempt ended, if there was one. Verbatim.
  final String note;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (note.isNotEmpty) ...[
          SkotiqBanner(
            tone: BannerTone.info,
            icon: LucideIcons.info,
            title: note,
          ),
          const SizedBox(height: SkotiqTokens.spaceXl),
        ],
        Text(
          'Two scans, from opposite directions',
          style:
              SkotiqTypography.bodyStrong.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'Skotiq will scan focus twice — once approaching every point '
          'from below, once from above — fit both curves and report the '
          "distance between them. That distance is your focuser's backlash, "
          'and autofocus uses it to compensate the final move.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceXl),
        Text(
          'What it needs',
          style:
              SkotiqTypography.labelStrong.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'Stars in the frame, focus already roughly set, and a few undisturbed '
          'minutes. Tracking should be running and the sky clear of the target '
          'for the whole measurement.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: SkotiqTokens.spaceXl),
        if (plan == null) const _PlanLoading() else _PlanSummary(plan: plan!),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Text(
          backlashVariesNotice,
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _PlanLoading extends StatelessWidget {
  const _PlanLoading();

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: SkotiqTokens.paddingMd,
      decoration: SkotiqDecorations.well(colors),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Reading the focuser position and travel limits…',
            style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          const SkotiqProgressBar(
            value: 0,
            indeterminate: true,
            style: SkotiqProgressStyle.thin,
          ),
        ],
      ),
    );
  }
}

class _PlanSummary extends StatelessWidget {
  const _PlanSummary({required this.plan});

  final FocuserBacklashCalibrationPlan plan;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Container(
      padding: SkotiqTokens.paddingMd,
      decoration: SkotiqDecorations.well(colors),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _DetailRow(
            icon: LucideIcons.clock,
            label: 'Time',
            value: describeEstimate(plan.estimatedDuration),
            note: 'An estimate. The real time depends on your exposure length '
                'and how fast the focuser moves.',
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _DetailRow(
            icon: LucideIcons.camera,
            label: 'Exposures',
            value: '${plan.totalExposures} '
                '(${plan.pointsPerScan} points per scan, two scans)',
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _DetailRow(
            icon: LucideIcons.gitCompare,
            label: 'Reversal budget',
            value: '${plan.reversalBudgetSteps} steps',
            note: 'The furthest this scan reverses the drive train, and so the '
                'widest backlash it could possibly expose. A focuser worse '
                'than that will be refused rather than under-reported.',
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          _DetailRow(
            icon: LucideIcons.moveHorizontal,
            label: 'Focuser travel',
            value: '${plan.travelLowPosition} to ${plan.travelHighPosition}',
            note: 'Points are sampled between ${plan.scanLowPosition} and '
                '${plan.scanHighPosition}; the extra room is the run-up each '
                'approach needs. The focuser is returned to where it started '
                'when the measurement ends, including if you cancel.',
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.note,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: SkotiqTokens.iconSm, color: colors.textMuted),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$label: $value',
                style:
                    SkotiqTypography.bodySm.copyWith(color: colors.textPrimary),
              ),
              if (note != null) ...[
                const SizedBox(height: SkotiqTokens.spaceXs),
                Text(
                  note!,
                  style: SkotiqTypography.caption
                      .copyWith(color: colors.textMuted),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// Progress

class _ProgressPanel extends StatelessWidget {
  const _ProgressPanel({required this.state});

  final FocuserBacklashCalibrationState state;

  static const _steps = <FocuserBacklashPhase>[
    FocuserBacklashPhase.scanningFromBelow,
    FocuserBacklashPhase.scanningFromAbove,
    FocuserBacklashPhase.analysing,
  ];

  static String _labelFor(FocuserBacklashPhase phase) => switch (phase) {
        FocuserBacklashPhase.scanningFromBelow => 'Scanning from below',
        FocuserBacklashPhase.scanningFromAbove => 'Scanning from above',
        FocuserBacklashPhase.analysing => 'Fitting both curves',
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final currentIndex = _steps.indexOf(state.phase);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _labelFor(state.phase),
          style:
              SkotiqTypography.sectionTitle.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        if (state.totalPoints > 0)
          Text(
            'Point ${state.currentPoint} of ${state.totalPoints}',
            style: SkotiqTypography.readoutSm
                .copyWith(color: colors.textSecondary),
          ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        SkotiqProgressBar(
          value: state.progress / 100,
          style: SkotiqProgressStyle.thin,
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          state.status,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        for (var i = 0; i < _steps.length; i++)
          Padding(
            padding: EdgeInsets.only(
              bottom: i == _steps.length - 1 ? 0 : SkotiqTokens.spaceSm,
            ),
            child: _StepRow(
              label: _labelFor(_steps[i]),
              done: currentIndex > i,
              active: currentIndex == i,
            ),
          ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _ScanChartPanel(
          belowPoints: state.belowPoints,
          abovePoints: state.abovePoints,
          scanRange: state.scanRange,
          liveApproach: switch (state.phase) {
            FocuserBacklashPhase.scanningFromBelow =>
              FocuserBacklashApproach.fromBelow,
            FocuserBacklashPhase.scanningFromAbove =>
              FocuserBacklashApproach.fromAbove,
            _ => null,
          },
          repaintTick: state.currentPoint,
        ),
      ],
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.label,
    required this.done,
    required this.active,
  });

  final String label;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final (dotColor, labelColor) = done
        ? (colors.success, colors.textSecondary)
        : active
            ? (colors.primary, colors.textPrimary)
            : (colors.textMuted, colors.textMuted);

    return Row(
      children: [
        SizedBox(
          width: SkotiqTokens.iconMd,
          child: Center(
            child: done
                ? Icon(
                    LucideIcons.check,
                    size: SkotiqTokens.iconSm,
                    color: colors.success,
                  )
                : StatusDot(
                    color: dotColor,
                    variant: active
                        ? StatusDotVariant.attention
                        : StatusDotVariant.static,
                  ),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceMd),
        Expanded(
          child: Text(
            label,
            style: SkotiqTypography.bodySm.copyWith(color: labelColor),
          ),
        ),
      ],
    );
  }
}

// Result — measured, and no-measurable-backlash

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.state, required this.result});

  final FocuserBacklashCalibrationState state;
  final FocuserBacklashResult result;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final c = result.calibration!;
    final measured = result.kind == FocuserBacklashOutcomeKind.measured;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (state.isSaved) ...[
          SkotiqBanner(
            title: measured
                ? 'Saved — autofocus will compensate ${c.steps} steps'
                : 'Saved — this focuser is on record as checked',
            tone: BannerTone.success,
            icon: LucideIcons.check,
          ),
          const SizedBox(height: SkotiqTokens.spaceLg),
        ],
        if (measured)
          _MeasuredHeadline(calibration: c)
        else
          _NoBacklashHeadline(calibration: c),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _ConfidenceBlock(calibration: c),
        const SizedBox(height: SkotiqTokens.spaceLg),
        _ScanChartPanel(
          belowPoints: c.below.points,
          abovePoints: c.above.points,
          belowVertex: c.below.optimumPosition,
          aboveVertex: c.above.optimumPosition,
          scanRange: state.scanRange,
        ),
        const SizedBox(height: SkotiqTokens.spaceMd),
        _ScanDetails(calibration: c),
        const SizedBox(height: SkotiqTokens.spaceMd),
        Text(
          backlashVariesNotice,
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _MeasuredHeadline extends StatelessWidget {
  const _MeasuredHeadline({required this.calibration});

  final FocuserBacklashCalibration calibration;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '${calibration.steps} steps',
          style: SkotiqTypography.readoutLg.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        // The provenance sub-line, in the house style: the figure never appears
        // without the conditions it was taken in.
        Text(
          'Measured at ${backlashConditions(calibration)}.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _NoBacklashHeadline extends StatelessWidget {
  const _NoBacklashHeadline({required this.calibration});

  final FocuserBacklashCalibration calibration;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final limit = calibration.resolutionLimitSteps;
    // A clean result, not a failure: plenty of focusers genuinely have no
    // backlash worth compensating, and the measurement that proves it is worth
    // keeping. Toned as success and worded as a finding.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Icon(
              LucideIcons.checkCircle,
              size: SkotiqTokens.iconLg,
              color: colors.success,
            ),
            const SizedBox(width: SkotiqTokens.spaceMd),
            Expanded(
              child: Text(
                'No measurable backlash',
                style: SkotiqTypography.sectionTitle
                    .copyWith(color: colors.textPrimary),
              ),
            ),
          ],
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          'No backlash larger than ${limit.toStringAsFixed(0)} steps was '
          'detectable — that is the smallest difference these two scans could '
          'resolve. Compensation stays at 0.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceXs),
        Text(
          'Measured at ${backlashConditions(calibration)}. '
          'Saving records that this focuser was checked.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }
}

class _ConfidenceBlock extends StatelessWidget {
  const _ConfidenceBlock({required this.calibration});

  final FocuserBacklashCalibration calibration;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqChip(
          label: confidenceLabel(calibration.confidence),
          tone: confidenceTone(calibration.confidence),
          dot: true,
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        // Verbatim from native: it is written for the operator and says what
        // would make the next measurement better.
        Text(
          calibration.confidenceReason,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}

/// The per-scan numbers behind the headline: where each fit landed, how well it
/// fitted, and how much clearance the answer had.
class _ScanDetails extends StatelessWidget {
  const _ScanDetails({required this.calibration});

  final FocuserBacklashCalibration calibration;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final below = calibration.below;
    final above = calibration.above;
    return Container(
      padding: SkotiqTokens.paddingMd,
      decoration: SkotiqDecorations.well(colors),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _FactRow(
            label: 'From below',
            value: 'optimum ${below.optimumPosition}, '
                'R² ${below.rSquared.toStringAsFixed(3)}, '
                '${below.points.length} points',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _FactRow(
            label: 'From above',
            value: 'optimum ${above.optimumPosition}, '
                'R² ${above.rSquared.toStringAsFixed(3)}, '
                '${above.points.length} points',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _FactRow(
            label: 'Vertex difference',
            value: '${calibration.vertexDifference} steps '
                '(resolution limit '
                '${calibration.resolutionLimitSteps.toStringAsFixed(0)})',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _FactRow(
            label: 'Run-up per point',
            value: '${calibration.clearanceSteps} steps',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          // The ceiling on what this run could have found: a dead band wider
          // than the drive train was reversed by did not come from a dead
          // band. Shown because it is what makes the figure above believable,
          // and `confidenceReason` says so in words when the result crowds it.
          _FactRow(
            label: 'Reversal budget',
            value: '${calibration.reversalBudgetSteps} steps total, '
                '${calibration.reversalBudgetAtVertexSteps} by the vertex — '
                'the widest backlash this run could expose',
          ),
          const SizedBox(height: SkotiqTokens.spaceSm),
          _FactRow(
            label: 'Focuser',
            value: '${calibration.focuserDeviceId} · '
                'Skotiq ${calibration.appVersion}',
          ),
        ],
      ),
    );
  }
}

class _FactRow extends StatelessWidget {
  const _FactRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 130,
          child: Text(
            label,
            style:
                SkotiqTypography.readoutLabel.copyWith(color: colors.textMuted),
          ),
        ),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Expanded(
          child: Text(
            value,
            style: SkotiqTypography.monoCaption
                .copyWith(color: colors.textSecondary),
          ),
        ),
      ],
    );
  }
}

// Refusal

class _RefusalPanel extends StatelessWidget {
  const _RefusalPanel({required this.state, required this.result});

  final FocuserBacklashCalibrationState state;
  final FocuserBacklashResult result;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final refusal = result.refusal!;
    final hasPoints =
        state.belowPoints.isNotEmpty || state.abovePoints.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqBanner(
          tone: refusalTone(refusal.code),
          icon: refusalIcon(refusal.code),
          title: refusalHeading(refusal.code),
          // Verbatim from native. The reason and the remedy are written for the
          // operator and are not paraphrased here.
          message: refusal.message,
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Text(
          'What to try',
          style:
              SkotiqTypography.labelStrong.copyWith(color: colors.textPrimary),
        ),
        const SizedBox(height: SkotiqTokens.spaceSm),
        Text(
          refusal.remedy,
          style: SkotiqTypography.bodySm.copyWith(color: colors.textSecondary),
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Text(
          'No figure was saved and your backlash setting is untouched. A '
          'measurement Skotiq cannot stand behind is worse than none.',
          style: SkotiqTypography.caption.copyWith(color: colors.textMuted),
        ),
        if (hasPoints) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          // The points that WERE collected, so the operator can see for
          // themselves what the refusal is about.
          _ScanChartPanel(
            belowPoints: state.belowPoints,
            abovePoints: state.abovePoints,
            scanRange: state.scanRange,
          ),
        ],
      ],
    );
  }
}

// Failure — hardware or cancellation, which is a different thing from a refusal

class _FailurePanel extends StatelessWidget {
  const _FailurePanel({required this.state});

  final FocuserBacklashCalibrationState state;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final hasPoints =
        state.belowPoints.isNotEmpty || state.abovePoints.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SkotiqBanner(
          tone: BannerTone.error,
          icon: LucideIcons.alertTriangle,
          title: 'The measurement stopped before it finished',
          message: state.errorMessage ?? state.status,
        ),
        const SizedBox(height: SkotiqTokens.spaceLg),
        Text(
          'This is not a refusal — the run did not get far enough to have an '
          'opinion. Nothing was saved and your backlash setting is untouched.',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
        if (hasPoints) ...[
          const SizedBox(height: SkotiqTokens.spaceLg),
          _ScanChartPanel(
            belowPoints: state.belowPoints,
            abovePoints: state.abovePoints,
            scanRange: state.scanRange,
          ),
        ],
      ],
    );
  }
}

// The two-curve chart, shared by every surface that has points

/// The two approach curves on shared axes, with a legend.
///
/// Shared axes are the measurement: the horizontal gap between the two fitted
/// vertices IS the backlash, and two independently scaled charts would destroy
/// the only thing worth looking at.
class _ScanChartPanel extends StatelessWidget {
  const _ScanChartPanel({
    required this.belowPoints,
    required this.abovePoints,
    this.belowVertex,
    this.aboveVertex,
    this.scanRange,
    this.liveApproach,
    this.repaintTick = 0,
  });

  final List<VCurvePoint> belowPoints;
  final List<VCurvePoint> abovePoints;
  final int? belowVertex;
  final int? aboveVertex;
  final FocusRange? scanRange;

  /// The scan currently acquiring, whose newest point is ringed.
  final FocuserBacklashApproach? liveApproach;

  final int repaintTick;

  /// Chart height. Tall enough that a shallow V still reads as a V at the
  /// dialog's 720px width.
  static const double _chartHeight = 220;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final belowColor = SkotiqChartColors.forTheme(
      SkotiqChartColors.seriesBlue,
      colors,
    );
    final aboveColor = SkotiqChartColors.forTheme(
      SkotiqChartColors.seriesAmber,
      colors,
    );

    if (belowPoints.isEmpty && abovePoints.isEmpty) {
      return Container(
        height: _chartHeight,
        decoration: SkotiqDecorations.well(colors),
        alignment: Alignment.center,
        child: Text(
          'Waiting for the first point…',
          style: SkotiqTypography.bodySm.copyWith(color: colors.textMuted),
        ),
      );
    }

    return SkotiqPanel(
      // The content is a chart and should run to the panel corners.
      flush: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: _chartHeight,
            child: VCurveChart(
              focusRange: scanRange,
              gridColor: colors.border,
              textColor: colors.textMuted,
              repaintTick: repaintTick,
              series: [
                VCurveSeries(
                  points: belowPoints,
                  color: belowColor,
                  label: 'From below',
                  vertexPosition: belowVertex,
                  showVertexGuide: true,
                  highlightLatest:
                      liveApproach == FocuserBacklashApproach.fromBelow,
                ),
                VCurveSeries(
                  points: abovePoints,
                  color: aboveColor,
                  label: 'From above',
                  vertexPosition: aboveVertex,
                  showVertexGuide: true,
                  highlightLatest:
                      liveApproach == FocuserBacklashApproach.fromAbove,
                ),
              ],
            ),
          ),
          Padding(
            padding: SkotiqTokens.paddingMd,
            child: Wrap(
              spacing: SkotiqTokens.spaceLg,
              runSpacing: SkotiqTokens.spaceSm,
              children: [
                _LegendEntry(
                  color: belowColor,
                  label: 'From below',
                  vertex: belowVertex,
                  pointCount: belowPoints.length,
                ),
                _LegendEntry(
                  color: aboveColor,
                  label: 'From above',
                  vertex: aboveVertex,
                  pointCount: abovePoints.length,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({
    required this.color,
    required this.label,
    required this.vertex,
    required this.pointCount,
  });

  final Color color;
  final String label;
  final int? vertex;
  final int pointCount;

  @override
  Widget build(BuildContext context) {
    final colors = context.skotiqColors;
    final detail = vertex != null
        ? 'optimum $vertex'
        : '$pointCount ${pointCount == 1 ? 'point' : 'points'}';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        StatusDot(color: color),
        const SizedBox(width: SkotiqTokens.spaceSm),
        Text(
          '$label — $detail',
          style: SkotiqTypography.caption.copyWith(color: colors.textSecondary),
        ),
      ],
    );
  }
}
