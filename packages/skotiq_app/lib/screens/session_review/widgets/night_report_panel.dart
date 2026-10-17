import 'package:flutter/material.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_ui/skotiq_ui.dart';

/// Which part of the Night Doctor report a [NightReportPanel] renders.
///
/// The design's narrative order puts the verdict at slot 2 and the finding
/// cards at slot 4 — *after* the "proof it's optimal" improvement curve — so the
/// narrative view renders [NightReportSection.verdict] and
/// [NightReportSection.findings] in separate slots. Standalone surfaces (and the
/// golden) render [NightReportSection.both] as one block.
enum NightReportSection {
  /// The verdict header only (headline + 0..100 score ring).
  verdict,

  /// The ranked finding cards only (most-urgent-first).
  findings,

  /// Verdict header followed immediately by the finding cards.
  both,
}

/// The Night Doctor's verdict for one session/target, rendered as the narrative
/// centerpiece of the Morning Report.
///
/// Layout ([NightReportSection.both]): a verdict header (big plain-language
/// [NightReport.headline] paired with a 0..100 score ring), then the
/// [NightReport.findings] ranked most-urgent-first as severity-tinted
/// [SkotiqCard]s. Each finding card carries its title, explanation, a "next
/// time" advice line, evidence sub chips, and — when the detector supplied one —
/// an inline metric sparkline.
///
/// The narrative view splits these across the scroll ([section] =
/// [NightReportSection.verdict] then [NightReportSection.findings]) so the
/// findings land *after* the improvement curve.
///
/// Pure presentation: the panel reads a seeded model and owns no state. A null
/// (or fully-empty) [report] renders a tasteful "analysis pending" placeholder
/// so the slot never collapses while the native analysis is still running. When
/// [section] is [NightReportSection.findings], a null report renders nothing
/// (the verdict slot already showed the pending placeholder).
class NightReportPanel extends StatelessWidget {
  final NightReport? report;

  /// Which part of the report to render. Defaults to [NightReportSection.both].
  final NightReportSection section;

  /// Tapped on an evidence sub chip: the `captured_images.id` the detector
  /// blamed, so the host can open that frame. Null leaves the chips inert.
  final void Function(int imageId)? onEvidenceTap;

  const NightReportPanel({
    super.key,
    required this.report,
    this.section = NightReportSection.both,
    this.onEvidenceTap,
  });

  @override
  Widget build(BuildContext context) {
    final report = this.report;
    if (report == null) {
      // The verdict slot owns the pending placeholder; the findings-only slot
      // stays empty so the narrative doesn't show two "pending" cards.
      return section == NightReportSection.findings
          ? const SizedBox.shrink()
          : const _AnalysisPending();
    }

    final showVerdict = section != NightReportSection.findings;
    final showFindings = section != NightReportSection.verdict;

    // Rank findings most-urgent-first so the eye lands on critical problems.
    final findings = [...report.findings]
      ..sort((a, b) => b.severity.index.compareTo(a.severity.index));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showVerdict) _VerdictHeader(report: report),
        if (showFindings)
          if (findings.isEmpty) ...[
            // Keep the calm "clean night" state attached to whichever slot
            // renders findings; pad it off the verdict only when both show.
            // An un-graded night gets nothing here: "no problems found" would be
            // a claim the analysis never made.
            if (report.graded) ...[
              if (showVerdict) const SizedBox(height: SkotiqTokens.spaceMd),
              const _NoFindings(),
            ],
          ] else
            ...findings.asMap().entries.map(
                  (e) => Padding(
                    // No top pad on the first findings-only card (the section
                    // header above already spaces it); otherwise space each card.
                    padding: EdgeInsets.only(
                      top: (e.key == 0 && !showVerdict)
                          ? 0
                          : SkotiqTokens.spaceMd,
                    ),
                    child: _FindingCard(
                      finding: e.value,
                      onEvidenceTap: onEvidenceTap,
                    ),
                  ),
                ),
      ],
    );
  }
}

/// Maps a [NightFindingSeverity] to the matching semantic colour + icon, per
/// the brief (info→info, warn→warning, critical→error).
class _SeverityStyle {
  final Color color;
  final IconData icon;
  final String label;

  const _SeverityStyle(this.color, this.icon, this.label);

  factory _SeverityStyle.of(
    NightFindingSeverity severity,
    SkotiqColors colors,
  ) {
    switch (severity) {
      case NightFindingSeverity.critical:
        return _SeverityStyle(
            colors.error, SkotiqIcons.critical, 'Critical');
      case NightFindingSeverity.warn:
        return _SeverityStyle(
            colors.warning, SkotiqIcons.warning, 'Warning');
      case NightFindingSeverity.info:
        return _SeverityStyle(colors.info, SkotiqIcons.info, 'Info');
    }
  }
}

/// Maps the 0..100 score to a verdict colour band: high→success, mid→warning,
/// low→error. Keeps the ring + grade colour in lockstep.
Color _scoreColor(int score, SkotiqColors colors) {
  if (score >= 75) return colors.success;
  if (score >= 50) return colors.warning;
  return colors.error;
}

String _scoreGrade(int score) {
  if (score >= 90) return 'Excellent';
  if (score >= 75) return 'Good';
  if (score >= 50) return 'Fair';
  if (score >= 25) return 'Poor';
  return 'Difficult';
}

class _VerdictHeader extends StatelessWidget {
  final NightReport report;

  const _VerdictHeader({required this.report});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    // An un-graded night has no number to show: the grade would be a 100/100
    // "Excellent" earned by having produced nothing to measure.
    final graded = report.graded;
    final score = report.score.clamp(0, 100);
    final scoreColor = graded ? _scoreColor(score, colors) : colors.textMuted;

    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceXl),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (graded)
            _ScoreRing(score: score, color: scoreColor)
          else
            _UngradedRing(color: colors.textMuted, track: colors.border),
          const SizedBox(width: SkotiqTokens.spaceXl),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      SkotiqIcons.brain,
                      size: SkotiqTokens.iconSm,
                      color: colors.textMuted,
                    ),
                    const SizedBox(width: SkotiqTokens.spaceSm),
                    Text(
                      'Night Doctor',
                      style: SkotiqTypography.overline.copyWith(
                        color: colors.textMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: SkotiqTokens.spaceSm),
                Text(
                  report.headline.isEmpty
                      ? (graded
                          ? 'Your night, summarised.'
                          : 'Not graded — this night had nothing to analyse.')
                      : report.headline,
                  style: SkotiqTypography.sectionTitle.copyWith(
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: SkotiqTokens.spaceMd),
                Wrap(
                  spacing: SkotiqTokens.spaceSm,
                  runSpacing: SkotiqTokens.spaceSm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _GradeChip(
                      label: graded ? _scoreGrade(score) : 'Not graded',
                      color: scoreColor,
                    ),
                    Text(
                      // "0 findings" on an un-graded night would imply the
                      // checks ran and came back clean; they never ran.
                      (!graded && report.findings.isEmpty)
                          ? 'nothing to analyse'
                          : '${report.findings.length} finding'
                              '${report.findings.length == 1 ? '' : 's'}',
                      style: SkotiqTypography.bodySm.copyWith(
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A 0..100 score drawn as a ring (sweep ∝ score) with the number centred.
class _ScoreRing extends StatelessWidget {
  final int score;
  final Color color;

  const _ScoreRing({required this.score, required this.color});

  static const double _size = 96;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SizedBox(
      width: _size,
      height: _size,
      child: CustomPaint(
        painter: _ScoreRingPainter(
          fraction: (score / 100).clamp(0.0, 1.0),
          color: color,
          track: colors.border,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$score',
                style: SkotiqTypography.telemetryLg.copyWith(
                  color: color,
                ),
              ),
              Text(
                '/ 100',
                style: SkotiqTypography.captionSm.copyWith(
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The score ring's un-graded twin: the same footprint (so the header does not
/// reflow) with an empty track and an em dash where the number would be. Used
/// when [NightReport.graded] is false — there is no grade to draw.
class _UngradedRing extends StatelessWidget {
  final Color color;
  final Color track;

  const _UngradedRing({required this.color, required this.track});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _ScoreRing._size,
      height: _ScoreRing._size,
      child: CustomPaint(
        painter: _ScoreRingPainter(fraction: 0, color: color, track: track),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '—',
                style: SkotiqTypography.telemetryLg.copyWith(color: color),
              ),
              Text(
                'not graded',
                style: SkotiqTypography.captionSm.copyWith(color: color),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScoreRingPainter extends CustomPainter {
  final double fraction;
  final Color color;
  final Color track;

  _ScoreRingPainter({
    required this.fraction,
    required this.color,
    required this.track,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 8.0;
    final rect = Offset.zero & size;
    final center = rect.center;
    final radius = (size.shortestSide - stroke) / 2;

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    if (fraction <= 0) return;
    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = color;
    // Start at 12 o'clock, sweep clockwise.
    const start = -90 * 3.1415926535 / 180;
    final sweep = fraction * 2 * 3.1415926535;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      arcPaint,
    );
  }

  @override
  bool shouldRepaint(_ScoreRingPainter old) =>
      old.fraction != fraction || old.color != color || old.track != track;
}

class _GradeChip extends StatelessWidget {
  final String label;
  final Color color;

  const _GradeChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      height: SkotiqChip.height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqChip.horizontalPadding,
      ),
      // The chip decoration, not a pill: 02 allows four radii (4 / 6 / 8 / 12)
      // and `radiusFull` is not one of them. The tone supplies the fill at
      // `opacityStatusFill` and the ink.
      decoration: SkotiqDecorations.chip(colors, tone: color),
      child: Text(
        label,
        style: SkotiqTypography.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _FindingCard extends StatelessWidget {
  final NightFinding finding;
  final void Function(int imageId)? onEvidenceTap;

  const _FindingCard({required this.finding, this.onEvidenceTap});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final style = _SeverityStyle.of(finding.severity, colors);

    return SkotiqPanel(
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left severity accent rail.
            Container(width: 4, color: style.color),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(style.icon,
                            size: SkotiqTokens.iconSm, color: style.color),
                        const SizedBox(width: SkotiqTokens.spaceSm),
                        Expanded(
                          child: Text(
                            finding.title.isEmpty ? style.label : finding.title,
                            style: SkotiqTypography.sectionTitle.copyWith(
                              color: colors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: SkotiqTokens.spaceSm),
                        _SeverityPill(style: style),
                      ],
                    ),
                    if (finding.explanation.isNotEmpty) ...[
                      const SizedBox(height: SkotiqTokens.spaceSm),
                      Text(
                        finding.explanation,
                        style: SkotiqTypography.bodySm.copyWith(
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                    if (finding.metricSeries != null &&
                        finding.metricSeries!.length > 1) ...[
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      _Sparkline(
                        values: finding.metricSeries!,
                        color: style.color,
                      ),
                    ],
                    if (finding.advice.isNotEmpty) ...[
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      _AdviceRow(advice: finding.advice),
                    ],
                    if (finding.evidenceSubIds.isNotEmpty) ...[
                      const SizedBox(height: SkotiqTokens.spaceMd),
                      _EvidenceChips(
                        subIds: finding.evidenceSubIds,
                        onEvidenceTap: onEvidenceTap,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeverityPill extends StatelessWidget {
  final _SeverityStyle style;

  const _SeverityPill({required this.style});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      height: SkotiqChip.height,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqChip.horizontalPadding,
      ),
      // The chip decoration, not a pill: 02 allows four radii (4 / 6 / 8 / 12)
      // and `radiusFull` is not one of them. The tone supplies the fill at
      // `opacityStatusFill` and the ink.
      decoration: SkotiqDecorations.chip(colors, tone: style.color),
      child: Text(
        style.label,
        style: SkotiqTypography.caption.copyWith(
          color: style.color,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

/// The "next time, try…" advice line — a lightbulb + the actionable text on a
/// quiet tinted surface so it reads as guidance, not a warning.
class _AdviceRow extends StatelessWidget {
  final String advice;

  const _AdviceRow({required this.advice});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      padding: const EdgeInsets.all(SkotiqTokens.spaceMd),
      decoration: BoxDecoration(
        color: colors.well,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(SkotiqIcons.idea,
              size: SkotiqTokens.iconSm, color: colors.accent),
          const SizedBox(width: SkotiqTokens.spaceSm),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: SkotiqTypography.bodySm.copyWith(
                  color: colors.textSecondary,
                ),
                children: [
                  TextSpan(
                    text: 'Next time  ',
                    style: SkotiqTypography.labelStrongSm.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  TextSpan(text: advice),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Evidence sub chips — the `captured_images.id`s the detector blamed, so the
/// user can jump to the offending frames.
class _EvidenceChips extends StatelessWidget {
  final List<int> subIds;
  final void Function(int imageId)? onEvidenceTap;

  const _EvidenceChips({required this.subIds, this.onEvidenceTap});

  static const int _maxShown = 8;

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final shown = subIds.take(_maxShown).toList();
    final overflow = subIds.length - shown.length;
    return Wrap(
      spacing: SkotiqTokens.spaceSm,
      runSpacing: SkotiqTokens.spaceSm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: SkotiqTokens.spaceXs),
          child: Text(
            'Evidence',
            style: SkotiqTypography.overline.copyWith(
              color: colors.textMuted,
            ),
          ),
        ),
        for (final id in shown)
          _EvidenceChip(
            label: 'sub $id',
            onTap: onEvidenceTap == null ? null : () => onEvidenceTap!(id),
          ),
        if (overflow > 0) _EvidenceChip(label: '+$overflow more'),
      ],
    );
  }
}

class _EvidenceChip extends StatelessWidget {
  final String label;

  /// When set, the chip becomes tappable and jumps to the backing frame; null
  /// for the non-frame '+N more' overflow chip.
  final VoidCallback? onTap;

  const _EvidenceChip({required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    final chip = Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SkotiqTokens.spaceSm,
        vertical: SkotiqTokens.spaceXs,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(SkotiqIcons.frame,
              size: SkotiqTokens.iconXs, color: colors.textMuted),
          const SizedBox(width: SkotiqTokens.spaceXs),
          Text(
            label,
            style: SkotiqTypography.monoXs.copyWith(
              color: colors.textSecondary,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return chip;
    return Semantics(
        button: true,
        enabled: true,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
          child: chip,
        ));
  }
}

/// A compact line chart of the finding's backing metric series (e.g. HFR over
/// the night), drawn token-pure with [CustomPaint] — too small to warrant the
/// fl_chart axes/legend overhead.
class _Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;

  const _Sparkline({required this.values, required this.color});

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return Container(
      height: 56,
      padding: const EdgeInsets.all(SkotiqTokens.spaceSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(SkotiqTokens.radiusSm),
        border: Border.all(color: colors.border),
      ),
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparklinePainter(
          values: values,
          color: color,
          fill: color.withValues(alpha: SkotiqTokens.opacitySubtle),
        ),
      ),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final Color fill;

  _SparklinePainter({
    required this.values,
    required this.color,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var min = values.first;
    var max = values.first;
    for (final v in values) {
      if (v < min) min = v;
      if (v > max) max = v;
    }
    final span = (max - min).abs() < 1e-9 ? 1.0 : (max - min);
    final dx = size.width / (values.length - 1);

    double yOf(double v) {
      // Invert so larger values sit higher; pad 10% top/bottom.
      final t = (v - min) / span;
      return size.height * (0.9 - t * 0.8);
    }

    final path = Path();
    final area = Path();
    for (var i = 0; i < values.length; i++) {
      final x = dx * i;
      final y = yOf(values[i]);
      if (i == 0) {
        path.moveTo(x, y);
        area.moveTo(x, size.height);
        area.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        area.lineTo(x, y);
      }
    }
    area.lineTo(size.width, size.height);
    area.close();

    canvas.drawPath(area, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.values != values || old.color != color || old.fill != fill;
}

/// Shown when a report exists but the Night Doctor flagged nothing — a calm,
/// positive "clean night" state rather than an empty void.
class _NoFindings extends StatelessWidget {
  const _NoFindings();

  @override
  Widget build(BuildContext context) {
    final colors = SkotiqColors.of(context);
    return SkotiqPanel(
      padding: const EdgeInsets.all(SkotiqTokens.spaceLg),
      child: Row(
        children: [
          Icon(SkotiqIcons.success,
              size: SkotiqTokens.iconMd, color: colors.success),
          const SizedBox(width: SkotiqTokens.spaceMd),
          Expanded(
            child: Text(
              'No issues detected — a clean night. Every sub looks usable.',
              style: SkotiqTypography.bodySm.copyWith(
                color: colors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Null/empty placeholder — the analysis hasn't landed yet. Tasteful, not an
/// error: a spinner-free "pending" card the narrative scroll can hold open.
class _AnalysisPending extends StatelessWidget {
  const _AnalysisPending();

  @override
  Widget build(BuildContext context) {
    return const SkotiqPanel(
      padding: EdgeInsets.all(SkotiqTokens.spaceLg),
      child: EmptyState.compact(
        icon: SkotiqIcons.brain,
        title: 'Analysis pending',
        body: 'The Night Doctor is still reviewing this session. The verdict, '
            'score, and findings will appear here once analysis completes.',
      ),
    );
  }
}
