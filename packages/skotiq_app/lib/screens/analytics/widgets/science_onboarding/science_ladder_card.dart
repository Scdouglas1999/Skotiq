import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

import 'science_ladder_model.dart';
import 'science_nav_row_card.dart';
import 'science_rung_sheet.dart';

class ScienceLadderCard extends ConsumerWidget {
  final bool hasCalibration;
  final bool hasTarget;
  final bool photometryLive;
  final int lightCurvePoints;
  final bool hasPeriodResult;
  final bool hasExportableData;
  final VoidCallback onJumpToPhotometry;

  /// Runs rung 1. Named for the action, not a destination: the rung's button
  /// says 'Run calibration', so a host that merely scrolls somewhere is not
  /// honouring it.
  final VoidCallback onRunCalibration;

  /// Runs rung 2. Same rule as [onRunCalibration]: the button says 'Pick a
  /// target', and the only control in the app that picks a photometry target
  /// is the science HUD on the imaging screen — not a chart section in
  /// Analytics, and certainly not the calibration wizard.
  final VoidCallback onPickTarget;
  final VoidCallback onOpenExport;

  const ScienceLadderCard({
    super.key,
    required this.hasCalibration,
    required this.hasTarget,
    required this.photometryLive,
    required this.lightCurvePoints,
    required this.hasPeriodResult,
    required this.hasExportableData,
    required this.onJumpToPhotometry,
    required this.onRunCalibration,
    required this.onPickTarget,
    required this.onOpenExport,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = SkotiqColors.of(context);
    final collapsed = ref.watch(
      scienceSettingsProvider.select(
        (s) => s.valueOrNull?.scienceGuideCollapsed ?? false,
      ),
    );

    final progress = evaluateLadder(
      hasCalibration: hasCalibration,
      hasTarget: hasTarget,
      photometryLive: photometryLive,
      lightCurvePoints: lightCurvePoints,
      hasPeriodResult: hasPeriodResult,
      hasExportableData: hasExportableData,
    );

    if (collapsed) {
      return _CollapsedRow(
          progress: progress, onExpand: () => _setCollapsed(ref, false));
    }

    final next = progress.nextActionable;
    final nextSpec =
        next == null ? null : kScienceLadder.firstWhere((s) => s.rung == next);

    return SkotiqCard(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration:
                    SkotiqDecorations.chip(colors, tone: colors.primary),
                child: Icon(
                  LucideIcons.flaskConical,
                  color: colors.primary,
                  size: SkotiqTokens.iconSm,
                ),
              ),
              const SizedBox(width: SkotiqTokens.spaceMd),
              Expanded(
                child: Text(
                  'Science guide',
                  style: SkotiqTypography.bodyStrong.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
              ),
              Semantics(
                button: true,
                enabled: true,
                label: 'Collapse science guide',
                child: SkotiqIconButton(
                  icon: LucideIcons.x,
                  tooltip: 'Collapse',
                  onPressed: () => _setCollapsed(ref, true),
                ),
              ),
            ],
          ),
          const SizedBox(height: SkotiqTokens.spaceMd),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < kScienceLadder.length; i++) ...[
                  if (i != 0) ...[
                    Container(
                      width: 16,
                      height: 1,
                      color: colors.border,
                    ),
                  ],
                  _RungChip(
                    index: i + 1,
                    spec: kScienceLadder[i],
                    state: progress.states[kScienceLadder[i].rung]!,
                    onTap: () => _openRung(context, ref, kScienceLadder[i]),
                  ),
                ],
              ],
            ),
          ),
          if (nextSpec != null) ...[
            const SizedBox(height: SkotiqTokens.spaceLg),
            Align(
              alignment: Alignment.centerLeft,
              child: SkotiqButton(
                label: nextSpec.ctaLabel,
                icon: LucideIcons.arrowRight,
                onPressed: () => _runCta(context, ref, nextSpec.rung),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _setCollapsed(WidgetRef ref, bool collapsed) {
    ref
        .read(scienceSettingsProvider.notifier)
        .setScienceGuideCollapsed(collapsed);
  }

  void _openRung(BuildContext context, WidgetRef ref, ScienceRungSpec spec) {
    final state = evaluateLadder(
      hasCalibration: hasCalibration,
      hasTarget: hasTarget,
      photometryLive: photometryLive,
      lightCurvePoints: lightCurvePoints,
      hasPeriodResult: hasPeriodResult,
      hasExportableData: hasExportableData,
    ).states[spec.rung]!;
    showScienceRungSheet(
      context,
      spec,
      state,
      prerequisite: _prerequisiteFor(spec.rung),
      onCta: () => _runCta(context, ref, spec.rung),
      // Deliberately NOT the rung's own CTA: rung 5's CTA opens the export hub,
      // and the rung is locked precisely because there is nothing to export.
      // The unlock action goes where the prerequisite is satisfied instead.
      //
      // And deliberately NOT onJumpToPhotometry: on the populated branch of the
      // Science tab that scrolls to the PHOTOMETRY section, which plots curves
      // and exports them. Rung 2's CTA was moved OFF that section for exactly
      // this reason ("it does not choose the star"), so routing the unlock
      // there would land the operator on an empty Differential Photometry card
      // — the same dead end one scroll further down. Every lockable
      // prerequisite (track a star, gather ten points, record something
      // exportable) is cleared while capturing, in the Science HUD, which is
      // where onPickTarget goes on both branches.
      unlockLabel:
          _prerequisiteFor(spec.rung) == null ? null : 'Open Science HUD',
      onUnlock: _prerequisiteFor(spec.rung) == null ? null : onPickTarget,
    );
  }

  void _runCta(BuildContext context, WidgetRef ref, ScienceRung rung) {
    switch (rung) {
      case ScienceRung.measure:
        onRunCalibration();
      case ScienceRung.track:
        onPickTarget();
      case ScienceRung.curve:
      case ScienceRung.period:
        onJumpToPhotometry();
      case ScienceRung.contribute:
        onOpenExport();
    }
  }

  /// Why a rung is locked. Shown only for [RungState.locked], so each string
  /// has to match the one condition that can actually lock that rung —
  /// otherwise the sheet states a prerequisite the user has already met.
  String? _prerequisiteFor(ScienceRung rung) {
    return switch (rung) {
      // Neither of these is ever locked: calibrating and picking a star need
      // nothing to happen first.
      ScienceRung.measure => null,
      ScienceRung.track => null,
      ScienceRung.curve =>
        'Track a star — live, or open a session that recorded photometry — to '
            'start collecting points.',
      ScienceRung.period => 'Gather at least ten light-curve points first.',
      ScienceRung.contribute =>
        'Record photometry, a photometric calibration or a moving-object '
            'candidate before exporting.',
    };
  }
}

class _RungChip extends StatelessWidget {
  final int index;
  final ScienceRungSpec spec;
  final RungState state;
  final VoidCallback onTap;

  const _RungChip({
    required this.index,
    required this.spec,
    required this.state,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final (accent, foreground, digit) = switch (state) {
      RungState.done => (colors.success, colors.success, colors.success),
      RungState.ready => (colors.primary, colors.textPrimary, colors.primary),
      RungState.locked => (
          colors.textMuted,
          colors.textMuted,
          colors.textSecondary
        ),
    };

    return Semantics(
        button: true,
        enabled: true,
        child: GestureDetector(
          onTap: onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              width: 132,
              constraints: const BoxConstraints(
                minHeight: SkotiqTokens.minTouchTarget,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: SkotiqTokens.spaceMd,
                vertical: SkotiqTokens.spaceSm + 2,
              ),
              decoration: state == RungState.ready
                  ? SkotiqDecorations.panelSelected(colors)
                  : BoxDecoration(
                      color: colors.well,
                      borderRadius: SkotiqTokens.borderRadiusMd,
                      border: Border.all(color: colors.border),
                    ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 22,
                    height: 22,
                    alignment: Alignment.center,
                    decoration: SkotiqDecorations.chip(colors, tone: accent),
                    child: state == RungState.done
                        ? Icon(LucideIcons.check, size: 12, color: accent)
                        : Text(
                            '$index',
                            style: SkotiqTypography.caption.copyWith(
                                color: digit, fontWeight: FontWeight.w600),
                          ),
                  ),
                  const SizedBox(width: SkotiqTokens.spaceSm),
                  Flexible(
                    child: Text(
                      spec.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: SkotiqTypography.caption.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ));
  }
}

class _CollapsedRow extends StatelessWidget {
  final ScienceLadderProgress progress;
  final VoidCallback onExpand;

  const _CollapsedRow({required this.progress, required this.onExpand});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final step = (progress.nextActionable == null ? 5 : progress.doneCount + 1)
        .clamp(1, 5);
    return ScienceNavRowCard(
      icon: LucideIcons.flaskConical,
      iconColor: colors.primary,
      label: 'Science guide — step $step of 5',
      labelColor: colors.textSecondary,
      onTap: onExpand,
    );
  }
}
