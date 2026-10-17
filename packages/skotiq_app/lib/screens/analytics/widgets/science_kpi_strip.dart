import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// KPI strip at the top of the Analytics Science tab.
///
/// Includes the four headline numbers plus trust indicators: each KPI now
/// shows where the value came from (catalog, # matched, RMS, solver) so a
/// user can decide how far to trust it without digging into the underlying
/// cards.
class ScienceKpiStrip extends StatelessWidget {
  final SkotiqColors colors;
  final FramePhotometricCalibrationRow? latestCalibration;
  final TransparencySampleRow? latestTransparency;
  final ScienceFrameQualityMetricsRow? latestFrameQuality;
  final int movingCandidateCount;

  const ScienceKpiStrip({
    super.key,
    required this.colors,
    required this.latestCalibration,
    required this.latestTransparency,
    required this.latestFrameQuality,
    required this.movingCandidateCount,
  });

  @override
  Widget build(BuildContext context) {
    final tiles = [
      _CalibrationKpi(colors: colors, calibration: latestCalibration),
      _TransparencyKpi(colors: colors, transparency: latestTransparency),
      _UniformityKpi(colors: colors, frameQuality: latestFrameQuality),
      _MovingObjectsKpi(colors: colors, count: movingCandidateCount),
    ];

    if (MediaQuery.sizeOf(context).width < 720) {
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: tiles,
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(child: tiles[i]),
        ],
      ],
    );
  }
}

class _CalibrationKpi extends StatelessWidget {
  final SkotiqColors colors;
  final FramePhotometricCalibrationRow? calibration;

  const _CalibrationKpi({required this.colors, required this.calibration});

  @override
  Widget build(BuildContext context) {
    final c = calibration;
    final headline = c == null
        ? kReadoutUnknown
        : c.isCalibrated
            ? 'Calibrated'
            : 'Uncalibrated';
    final value = c?.zeroPoint == null
        ? kReadoutUnknown
        : 'ZP ${c!.zeroPoint!.toStringAsFixed(2)}';
    final tone = c == null
        ? colors.textMuted
        : c.isCalibrated
            ? colors.success
            : colors.warning;
    final trust = c == null
        ? <_TrustChip>[]
        : <_TrustChip>[
            _TrustChip(
              icon: LucideIcons.bookOpen,
              label: _formatCatalog(c.catalogSource),
              tooltip: 'Catalog used for star matching',
            ),
            _TrustChip(
              icon: LucideIcons.star,
              label: '${c.matchedStarCount} matched',
              tooltip: 'Stars matched to the catalog',
              tone: c.matchedStarCount < 12 ? colors.warning : null,
            ),
            _TrustChip(
              icon: LucideIcons.scale,
              label: 'RMS ${c.calibrationRms.toStringAsFixed(2)}',
              tooltip:
                  'Photometric fit residual (mag). Lower is better; >0.2 hints at noise.',
              tone: c.calibrationRms > 0.2 ? colors.warning : null,
            ),
            _TrustChip(
              icon: LucideIcons.crosshair,
              label: c.solverId,
              tooltip: 'Plate solver that produced the WCS',
            ),
          ];

    return _KpiCard(
      colors: colors,
      title: 'Calibration',
      headline: headline,
      headlineTone: tone,
      value: value,
      trust: trust,
    );
  }

  static String _formatCatalog(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('apass')) return 'APASS';
    if (lower.contains('gaia')) return 'Gaia';
    if (lower.contains('tycho')) return 'Tycho';
    if (lower.contains('auto')) return 'auto';
    return raw;
  }
}

class _TransparencyKpi extends StatelessWidget {
  final SkotiqColors colors;
  final TransparencySampleRow? transparency;

  const _TransparencyKpi({required this.colors, required this.transparency});

  @override
  Widget build(BuildContext context) {
    final t = transparency;
    final pct = t?.transparencyPercent;
    final headline =
        pct == null ? kReadoutUnknown : '${pct.toStringAsFixed(1)}%';
    final tone = pct == null
        ? colors.textMuted
        : pct >= 90
            ? colors.success
            : pct >= 75
                ? colors.info
                : colors.warning;
    final trust = t == null
        ? const <_TrustChip>[]
        : <_TrustChip>[
            _TrustChip(
              icon: LucideIcons.cloud,
              label: t.qualityBucket,
              tooltip: 'Bucketed quality label',
            ),
            _TrustChip(
              icon: LucideIcons.activity,
              label: 'k=${t.extinctionCoefficient.toStringAsFixed(2)}',
              tooltip: 'Atmospheric extinction coefficient (mag/airmass)',
            ),
            _TrustChip(
              icon: LucideIcons.percent,
              label: '${(t.confidence * 100).round()}% conf',
              tooltip:
                  'Confidence in the transparency estimate based on the rolling calibration window',
              tone: t.confidence < 0.5 ? colors.warning : null,
            ),
          ];

    return _KpiCard(
      colors: colors,
      title: 'Transparency',
      headline: headline,
      headlineTone: tone,
      value: t == null ? kReadoutUnknown : 'Sky model',
      trust: trust,
    );
  }
}

class _UniformityKpi extends StatelessWidget {
  final SkotiqColors colors;
  final ScienceFrameQualityMetricsRow? frameQuality;

  const _UniformityKpi({required this.colors, required this.frameQuality});

  @override
  Widget build(BuildContext context) {
    final fq = frameQuality;
    final value =
        fq == null ? kReadoutUnknown : fq.uniformityCv.toStringAsFixed(3);
    final tone = fq == null
        ? colors.textMuted
        : fq.uniformityCv > 0.28
            ? colors.warning
            : colors.success;
    final trust = fq == null
        ? const <_TrustChip>[]
        : <_TrustChip>[
            _TrustChip(
              icon: LucideIcons.barChart3,
              label: 'SNR ${fq.snr.toStringAsFixed(1)}',
              tooltip: 'Frame SNR — higher is better',
              tone: fq.snr < 10 ? colors.warning : null,
            ),
            _TrustChip(
              icon: LucideIcons.arrowUpRight,
              label: 'Clip↑ ${fq.highClipPercent.toStringAsFixed(2)}%',
              tooltip: 'Fraction of pixels at saturation',
              tone: fq.highClipPercent > 1.5 ? colors.warning : null,
            ),
            _TrustChip(
              icon: LucideIcons.arrowDownLeft,
              label: 'Clip↓ ${fq.lowClipPercent.toStringAsFixed(2)}%',
              tooltip: 'Fraction of pixels at the noise floor',
              tone: fq.lowClipPercent > 1.5 ? colors.warning : null,
            ),
          ];

    return _KpiCard(
      colors: colors,
      title: 'Uniformity CV',
      headline: value,
      headlineTone: tone,
      value: fq == null ? 'No frame metrics yet' : 'Lower is flatter',
      trust: trust,
    );
  }
}

class _MovingObjectsKpi extends StatelessWidget {
  final SkotiqColors colors;
  final int count;

  const _MovingObjectsKpi({required this.colors, required this.count});

  @override
  Widget build(BuildContext context) {
    final tone = count == 0 ? colors.textMuted : colors.success;
    return _KpiCard(
      colors: colors,
      title: 'Moving objects',
      headline: count.toString(),
      headlineTone: tone,
      value: count == 0 ? 'No candidates' : 'Live track overlay ready',
      trust: const <_TrustChip>[],
    );
  }
}

class _TrustChip {
  final IconData icon;
  final String label;
  final String tooltip;
  final Color? tone;

  const _TrustChip({
    required this.icon,
    required this.label,
    required this.tooltip,
    this.tone,
  });
}

class _KpiCard extends StatelessWidget {
  final SkotiqColors colors;
  final String title;
  final String headline;
  final Color headlineTone;
  final String value;
  final List<_TrustChip> trust;

  const _KpiCard({
    required this.colors,
    required this.title,
    required this.headline,
    required this.headlineTone,
    required this.value,
    required this.trust,
  });

  @override
  Widget build(BuildContext context) {
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: SkotiqTypography.caption.copyWith(
                color: colors.textMuted,
                letterSpacing: 0.6,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 6),
          Text(
            headline,
            style: SkotiqTypography.readoutLg
                .copyWith(color: headlineTone, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style:
                SkotiqTypography.caption.copyWith(color: colors.textSecondary),
          ),
          if (trust.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: trust
                  .map(
                    (t) => Tooltip(
                      message: t.tooltip,
                      preferBelow: false,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: SkotiqDecorations.chip(colors,
                            tone: t.tone ?? colors.textMuted),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(t.icon,
                                size: 10,
                                color: t.tone ?? colors.textSecondary),
                            const SizedBox(width: 3),
                            Text(
                              t.label,
                              style: SkotiqTypography.caption.copyWith(
                                  color: t.tone ?? colors.textSecondary,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}
