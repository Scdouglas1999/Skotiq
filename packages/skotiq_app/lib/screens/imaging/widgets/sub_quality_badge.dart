import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Compact per-sub quality badge for the live preview.
///
/// Surfaces the three quality metrics that matter at the eyepiece while a
/// sub is on screen — HFR, eccentricity, and star count — alongside an
/// ACCEPT/REJECT verdict computed from the *same* [FrameGradeRules] engine
/// the persisted auto-grader uses, so the live badge and the on-disk grade
/// never disagree.
///
/// Why a distinct widget from [ImageStatsOverlay]: that overlay is a generic
/// raw-stats readout (median/mean/etc.) painted on an ad-hoc black scrim.
/// This badge is quality-focused, opinionated, and styled to match the other
/// top-right preview badges ([RawPreviewStatusBadge] / the calibrated badge):
/// a translucent [SkotiqColors.surface] pill with a 1px border, not a
/// black overlay. Keeping it separate also keeps ownership clean — the host
/// widget positions this badge independently of the stats overlay.
///
/// Reads:
/// * [lastImageStatsProvider] — the HFR / star-count snapshot of the most
///   recently captured frame. When `null` (no frame yet) the badge renders
///   nothing rather than fabricating zeros — an honest empty state.
/// * [scienceSettingsProvider] — resolved into [FrameGradeRules]; the verdict
///   chip only appears when the rules actually grade something
///   ([FrameGradeRules.hasActiveRules]).
/// * [guideStatsProvider] — live total RMS in **arcseconds**
///   ([Phd2GuideStats.rmsTotal] is PHD2's calibrated arcsecond residual; see
///   its field docs and the `GuideHealthCard` arcsecond readout), fed into
///   [FrameGradeRules.gradeStats] against [FrameGradeRules.maxGuidingRmsTotalArcsec]
///   so a guiding excursion can reject a sub exactly as the auto-grader would.
///   Units match end to end: the threshold, the live value, and the rendered
///   `"` glyph in the reject reason are all arcseconds.
///
/// [eccentricity] is injected by the host because [ImageStats] does not carry
/// it; C6 pulls it from the per-frame science row by `currentFrameImageId` and
/// passes `null` when no science measurement exists for the frame, which the
/// badge renders as `ECC —` (and which causes the eccentricity rule, if any,
/// to be skipped — matching [FrameGradeRules.gradeStats] semantics).
class SubQualityBadge extends ConsumerWidget {
  /// Per-frame eccentricity from the science row, or `null` when unavailable.
  final double? eccentricity;

  /// Whether to draw the HFR / ECC / star chips.
  ///
  /// False where another surface on screen already carries those three
  /// numbers, so the badge does not say the same measurement twice. The
  /// verdict chip is drawn either way. The imaging canvas uses
  /// [SubQualityVerdict] inside its frame-info pill instead.
  final bool showMetrics;

  const SubQualityBadge({
    super.key,
    this.eccentricity,
    this.showMetrics = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(lastImageStatsProvider);

    // Honest empty state: no captured frame yet means nothing to grade.
    if (stats == null) return const SizedBox.shrink();

    final colors = SkotiqColors.of(context);
    final grade = _grade(ref, stats, eccentricity);
    final effectiveEccentricity = grade.eccentricity;

    final hfrText = stats.hfr != null ? stats.hfr!.toStringAsFixed(2) : '—';
    final eccText = effectiveEccentricity != null
        ? effectiveEccentricity.toStringAsFixed(2)
        : '—';
    final starText = stats.starCount != null ? '${stats.starCount}' : '—';

    final hasRules = grade.hasRules;
    if (!showMetrics && !hasRules) return const SizedBox.shrink();
    final rejectReason = grade.rejectReason;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: SkotiqTokens.opacityStrong),
        borderRadius: SkotiqTokens.borderRadiusMd,
        border: Border.all(color: colors.border),
      ),
      child: Padding(
        padding: SkotiqTokens.paddingSm,
        // Wrap, not Row: this badge floats over the preview inside a bounded
        // overlay width. A rigid Row of chips overflowed that box (47 px on an
        // 800x600 window with the "Large" font setting) and pushed the star
        // count and the ACCEPT/REJECT verdict off the canvas. Wrapping keeps
        // every chip on screen and still renders as a single line whenever the
        // overlay has room.
        child: Wrap(
          spacing: SkotiqTokens.spaceMd,
          runSpacing: SkotiqTokens.spaceXs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (showMetrics) ...[
              _MetricChip(label: 'HFR', value: hfrText, colors: colors),
              _MetricChip(label: 'ECC', value: eccText, colors: colors),
              _MetricChip(
                label: null,
                value: starText,
                trailingGlyph: '★',
                colors: colors,
              ),
            ],
            if (hasRules) _VerdictChip(reason: rejectReason, colors: colors),
          ],
        ),
      ),
    );
  }
}

/// The live verdict for the frame on screen, graded exactly as the persisted
/// auto-grader grades it.
typedef _Grade = ({
  bool hasRules,
  String? rejectReason,
  double? eccentricity,
});

_Grade _grade(WidgetRef ref, ImageStats stats, double? injectedEccentricity) {
  final rules = ref.watch(
    scienceSettingsProvider.select(
      (async) => async.valueOrNull?.resolvedFrameGradeRules(),
    ),
  );
  // Live guiding RMS (arcseconds) only matters for the verdict; select the
  // single field so the badge does not rebuild on every unrelated guide-stat
  // tick. This is the same arcsecond value GuideHealthCard renders, compared
  // against the arcsecond maxGuidingRmsTotalArcsec threshold.
  final guidingRmsTotal = ref.watch(
    guideStatsProvider.select((s) => s.rmsTotal),
  );

  // Prefer the live per-frame eccentricity now measured by the native star
  // detector and carried on [ImageStats]; fall back to the injected
  // science-row value only when the live frame did not measure it (too few
  // reliable stars). Either may be null → skipped by the grade rule, matching
  // [FrameGradeRules.gradeStats] semantics.
  final eccentricity = stats.eccentricity ?? injectedEccentricity;

  // PHD2 reports 0.0 as its "no data yet" sentinel for rolling RMS; treat
  // that as "no guiding telemetry" so we never reject a frame on a phantom
  // perfect-zero RMS before the guider has produced a sample.
  final liveRms = guidingRmsTotal > 0 ? guidingRmsTotal : null;

  final hasRules = rules != null && rules.hasActiveRules;
  return (
    hasRules: hasRules,
    rejectReason: hasRules
        ? rules.gradeStats(
            stats,
            guidingRmsTotal: liveRms,
            eccentricity: eccentricity,
          )
        : null,
    eccentricity: eccentricity,
  );
}

/// The ACCEPT / REJECT verdict on its own, for the canvas's frame-info pill.
///
/// The verdict used to float in its own glass box in the bottom-left corner of
/// the image. It qualifies the same frame the pill names, so it rides inside
/// that pill instead of claiming another corner. Collapses to nothing with no
/// frame or no active grading rules.
class SubQualityVerdict extends ConsumerWidget {
  const SubQualityVerdict({super.key, this.eccentricity});

  /// Per-frame eccentricity from the science row, or `null` when unavailable.
  final double? eccentricity;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(lastImageStatsProvider);
    if (stats == null) return const SizedBox.shrink();
    final grade = _grade(ref, stats, eccentricity);
    if (!grade.hasRules) return const SizedBox.shrink();
    return _VerdictChip(
      reason: grade.rejectReason,
      colors: SkotiqColors.of(context),
    );
  }
}

/// A single telemetry metric: an optional muted label followed by a
/// tabular-figures mono value so digit changes between subs don't jitter the
/// layout. The star-count chip uses [trailingGlyph] ('★') instead of a label.
class _MetricChip extends StatelessWidget {
  final String? label;
  final String value;
  final String? trailingGlyph;
  final SkotiqColors colors;

  const _MetricChip({
    required this.label,
    required this.value,
    required this.colors,
    this.trailingGlyph,
  });

  @override
  Widget build(BuildContext context) {
    final valueStyle = SkotiqTypography.withTabular(
      SkotiqTypography.monoSm,
    ).copyWith(color: colors.textPrimary);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (label != null) ...[
          Text(
            label!,
            style: SkotiqTypography.labelQuiet.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(width: SkotiqTokens.spaceXs),
        ],
        Text(value, style: valueStyle),
        if (trailingGlyph != null) ...[
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            trailingGlyph!,
            style: SkotiqTypography.monoSm.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ],
    );
  }
}

/// ACCEPT / REJECT verdict pill. Green dot + check for accept, red dot + x for
/// reject; the reject variant wraps in a [SkotiqTooltip] exposing the
/// human-readable rejection reason from [FrameGradeRules.gradeStats].
class _VerdictChip extends StatelessWidget {
  /// `null` when the frame passes every active rule (ACCEPT); otherwise the
  /// rejection reason string.
  final String? reason;
  final SkotiqColors colors;

  const _VerdictChip({required this.reason, required this.colors});

  @override
  Widget build(BuildContext context) {
    final accepted = reason == null;
    final statusColor = accepted ? colors.success : colors.error;
    final label = accepted ? 'ACCEPT' : 'REJECT';
    final glyph = accepted ? SkotiqIcons.check : LucideIcons.x;

    final pill = DecoratedBox(
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: SkotiqTokens.opacityStatusFill),
        borderRadius: SkotiqTokens.borderRadiusSm,
        border: Border.all(
          color: statusColor.withValues(
            alpha: SkotiqTokens.opacityEmphasisBorder,
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SkotiqTokens.spaceSm,
          vertical: SkotiqTokens.spaceXs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(
              color: statusColor,
              variant: accepted
                  ? StatusDotVariant.static
                  : StatusDotVariant.attention,
            ),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Icon(glyph, size: SkotiqTokens.iconXs, color: statusColor),
            const SizedBox(width: SkotiqTokens.spaceXs),
            Text(
              label,
              style: SkotiqTypography.labelSm.copyWith(color: statusColor),
            ),
          ],
        ),
      ),
    );

    if (accepted) return pill;

    return SkotiqTooltip(message: reason!, child: pill);
  }
}
