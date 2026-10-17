// Frame badge and quality chip widgets.
part of '../live_frame_panel.dart';

/// Filter + exposure + live-quality metadata badge for the current frame.
///
/// Beyond filter/exposure this overlays the measured quality of the displayed
/// sub — HFR, eccentricity, star count, FWHM — colour-graded for HFR and
/// eccentricity, plus a compact HFR-vs-time sparkline so trends (focus
/// drifting, clouds rolling in) are visible at a glance. Quality fields appear
/// only when measured; an unanalysed frame shows just filter + exposure rather
/// than fabricated zeros.
///
/// Eccentricity is the per-frame median star roundness now measured by the
/// native star detector (carried on [ImageStats.eccentricity]); it renders only
/// when the detector could honestly measure it (enough reliable stars),
/// otherwise it is omitted — never shown as a fabricated 0.
class _FrameBadge extends StatelessWidget {
  final SkotiqColors colors;
  final String? filterLabel;
  final double exposure;
  final ImageStats? stats;
  final List<double> hfrHistory;

  const _FrameBadge({
    required this.colors,
    required this.filterLabel,
    required this.exposure,
    required this.stats,
    required this.hfrHistory,
  });

  Color _hfrColor(double hfr) {
    // Absolute HFR thresholds are arcsec-pixel dependent, but as a fraction-
    // free at-a-glance cue these match the conventional "tight/soft/bad"
    // bands most CMOS imaging trains read at. Relative trend is carried by
    // the sparkline; this is just a static colour cue for the latest value.
    if (hfr <= 3.0) return colors.success;
    if (hfr <= 5.0) return colors.warning;
    return colors.error;
  }

  Color _eccColor(double ecc) {
    // Eccentricity is 0 (round) → 1 (a line). These bands mirror the common
    // reject thresholds (≈0.6 catches trailed frames, ≈0.8 catastrophic
    // tracking): well-guided rigs sit comfortably under 0.5.
    if (ecc <= 0.5) return colors.success;
    if (ecc <= 0.7) return colors.warning;
    return colors.error;
  }

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final hfr = s?.hfr;
    final fwhm = s?.fwhm;
    final eccentricity = s?.eccentricity;
    final starCount = s?.starCount;

    final captionStyle = SkotiqTypography.withTabular(
      SkotiqTypography.captionSm.copyWith(
        fontWeight: FontWeight.w600,
        color: colors.textSecondary,
      ),
    );

    final firstRow = <Widget>[
      Icon(LucideIcons.filter, size: 10, color: colors.textMuted),
      const SizedBox(width: 4),
      Text(filterLabel ?? 'No filter', style: captionStyle),
      const SizedBox(width: 8),
      Container(width: 1, height: 10, color: colors.border),
      const SizedBox(width: 8),
      Text(
        '${exposure.toStringAsFixed(exposure >= 10 ? 0 : 1)}s',
        style: captionStyle,
      ),
    ];

    final qualityChips = <Widget>[
      if (hfr != null)
        _QualityChip(
          colors: colors,
          icon: LucideIcons.circleDot,
          label: 'HFR',
          value: hfr.toStringAsFixed(2),
          valueColor: _hfrColor(hfr),
        ),
      // Renders only when honestly measured (enough reliable stars).
      if (eccentricity != null)
        _QualityChip(
          colors: colors,
          icon: LucideIcons.circleDashed,
          label: 'Ecc',
          value: eccentricity.toStringAsFixed(2),
          valueColor: _eccColor(eccentricity),
        ),
      if (fwhm != null)
        _QualityChip(
          colors: colors,
          icon: LucideIcons.scan,
          label: 'FWHM',
          value: fwhm.toStringAsFixed(2),
        ),
      if (starCount != null)
        _QualityChip(
          colors: colors,
          icon: LucideIcons.star,
          label: 'Stars',
          value: '$starCount',
        ),
    ];

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
        border: Border.all(color: colors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: firstRow),
          if (qualityChips.isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < qualityChips.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  qualityChips[i],
                ],
              ],
            ),
          ],
          // Sparkline needs at least 2 points to draw a line.
          if (hfrHistory.length >= 2) ...[
            const SizedBox(height: 5),
            SizedBox(
              width: 96,
              height: 18,
              child: CustomPaint(
                painter: HfrSparklinePainter(
                  values: hfrHistory,
                  color: colors.primary,
                  fillColor: colors.primary.withValues(alpha: 0.15),
                  showLatestMarker: true,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One compact quality readout (HFR / FWHM / Stars) for the frame badge.
class _QualityChip extends StatelessWidget {
  final SkotiqColors colors;
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _QualityChip({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 10, color: colors.textMuted),
        const SizedBox(width: 3),
        Text(
          '$label ',
          style: SkotiqTypography.captionSm.copyWith(
            color: colors.textMuted,
            fontWeight: FontWeight.w500,
          ),
        ),
        Text(
          value,
          style: SkotiqTypography.withTabular(
            SkotiqTypography.captionSm.copyWith(
              fontWeight: FontWeight.w700,
              color: valueColor ?? colors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
