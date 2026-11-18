import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/models.dart';
import 'package:skotiq_core/providers.dart';
import 'package:skotiq_core/services.dart';

import '../../night_control/data/session/session_frames_provider.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Compact per-sub quality badge for the live preview.
///
/// Surfaces the three quality metrics that matter at the eyepiece while a
/// sub is on screen (HFR, eccentricity and star count) beside the run's
/// ACCEPT/REJECT verdict on that frame. The verdict is the run grader's, the
/// one the frame strip, the frame pill and Tonight's Last frame show: a
/// second grader here labelled frames "Rejected" that the run kept, and the
/// reverse (IC 405, 2026-11-16).
///
/// Why a distinct widget from [ImageStatsOverlay]: that overlay is a generic
/// raw-stats readout (median/mean/etc.) painted on an ad-hoc black scrim.
/// This badge is quality-focused and styled to match the other top-right
/// preview badges ([RawPreviewStatusBadge] / the calibrated badge).
///
/// Reads:
/// * [lastImageStatsProvider]: the HFR / star-count snapshot of the most
///   recently captured frame, the run's own measurement of it. When `null`
///   (no frame yet) the badge renders nothing rather than fabricating zeros.
/// * [nightFrameRunVerdictProvider]: the run's verdict on the frame on
///   screen. A frame no run graded (a manual capture) has no verdict chip.
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
    final verdict = _runVerdict(ref);
    final effectiveEccentricity = stats.eccentricity ?? eccentricity;

    final hfrText = stats.hfr != null ? stats.hfr!.toStringAsFixed(2) : '—';
    final eccText = effectiveEccentricity != null
        ? effectiveEccentricity.toStringAsFixed(2)
        : '—';
    final starText = stats.starCount != null ? '${stats.starCount}' : '—';

    if (!showMetrics && verdict == null) return const SizedBox.shrink();

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
            if (verdict != null) _VerdictChip(verdict: verdict, colors: colors),
          ],
        ),
      ),
    );
  }
}

/// The run's verdict on the frame on screen, or null when no run graded it.
NightFrameRunVerdict? _runVerdict(WidgetRef ref) {
  final path =
      ref.watch(currentImageProvider.select((image) => image?.filePath));
  return ref.watch(nightFrameRunVerdictProvider(path));
}

/// The ACCEPT / REJECT verdict on its own, for the canvas's frame-info pill.
///
/// The verdict used to float in its own glass box in the bottom-left corner of
/// the image. It qualifies the same frame the pill names, so it rides inside
/// that pill instead of claiming another corner. Collapses to nothing with no
/// frame or a frame no run graded.
class SubQualityVerdict extends ConsumerWidget {
  const SubQualityVerdict({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stats = ref.watch(lastImageStatsProvider);
    if (stats == null) return const SizedBox.shrink();
    final verdict = _runVerdict(ref);
    if (verdict == null) return const SizedBox.shrink();
    return _VerdictChip(verdict: verdict, colors: SkotiqColors.of(context));
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
/// reject; the reject variant wraps in a [SkotiqTooltip] with the run's own
/// reason.
class _VerdictChip extends StatelessWidget {
  final NightFrameRunVerdict verdict;
  final SkotiqColors colors;

  const _VerdictChip({required this.verdict, required this.colors});

  @override
  Widget build(BuildContext context) {
    final accepted = verdict.accepted;
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

    final reason = verdict.reason;
    if (accepted || reason == null) return pill;

    return SkotiqTooltip(message: reason, child: pill);
  }
}
