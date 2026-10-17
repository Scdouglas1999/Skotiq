part of '../diagnostics_screen.dart';

class _HealthGradeCard extends StatelessWidget {
  final OpticalTrainDiagnostics diagnostics;
  final SkotiqColors colors;

  const _HealthGradeCard({
    required this.diagnostics,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    // `OpticalHealthScore` owns the A..F bands so every surface (analytics,
    // exports) renders the same letter for the same raw scores.
    final health = diagnostics.healthScore;
    final gradeColor = _gradeColor(health.grade, colors);

    return _DiagCard(
      colors: colors,
      child: Column(
        children: [
          Text(
            'Optical Health',
            style: SkotiqTypography.h5.copyWith(color: colors.textPrimary),
          ),
          const SizedBox(height: 16),
          Container(
            width: 44,
            height: 44,
            decoration: SkotiqDecorations.kpiBadge(gradeColor),
            child: Center(
              child: Text(
                health.letterGrade,
                style: SkotiqTypography.telemetryLg.copyWith(
                  fontWeight: FontWeight.w800,
                  color: gradeColor,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            health.qualityLabel,
            style: SkotiqTypography.label.copyWith(color: gradeColor),
          ),
          const SizedBox(height: 6),
          // The legend for the two bars directly below, not an explainer for
          // the screen. They print PENALTY scores, where 0 is a clean optical
          // train and 100 is the worst measured, and that is the one
          // convention on this card a reader cannot infer: every other number
          // in Skotiq reads better as it rises. It names the SCORES — the
          // figures at the end of each bar — because the bar is the decoration
          // and the figure is the reading.
          //
          // The sentence that used to follow it ("Use this grade as a quick
          // summary before diving into the field map and findings") was a hint
          // sentence explaining the screen, which 07 "What NOT to do" forbids.
          Text(
            'Lower scores are better.',
            textAlign: TextAlign.center,
            style: SkotiqTypography.captionSm.copyWith(
              color: colors.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          // Score breakdown
          _ScoreBar(
            label: context.l10n.text('diagnosticsTilt'),
            value: diagnostics.tiltScore,
            colors: colors,
            measured: diagnostics.tiltMeasured,
          ),
          const SizedBox(height: 6),
          _ScoreBar(
            label: context.l10n.text('diagnosticsCollimation'),
            value: diagnostics.collimationScore,
            colors: colors,
            measured: diagnostics.collimationMeasured,
          ),
        ],
      ),
    );
  }

  // Maps the shared `OpticalHealthGrade` enum to the theme palette. The
  // model deliberately stays UI-agnostic; only the diagnostics widgets need
  // to know which colour ramp matches the letter.
  Color _gradeColor(OpticalHealthGrade grade, SkotiqColors colors) {
    switch (grade) {
      case OpticalHealthGrade.a:
      case OpticalHealthGrade.b:
        return colors.success;
      case OpticalHealthGrade.c:
        return colors.warning;
      case OpticalHealthGrade.d:
      case OpticalHealthGrade.f:
        return colors.error;
    }
  }
}

class _ScoreBar extends StatelessWidget {
  final String label;
  final double value;
  final SkotiqColors colors;

  /// False when the axis had no data behind it. A penalty of 0 is the best
  /// score, so an unmeasured axis otherwise draws an empty green bar reading
  /// "0" — visually identical to a perfect optical train.
  final bool measured;

  const _ScoreBar({
    required this.label,
    required this.value,
    required this.colors,
    this.measured = true,
  });

  @override
  Widget build(BuildContext context) {
    final clampedValue = value.clamp(0.0, 100.0);
    final barColor = !measured
        ? colors.textMuted
        : clampedValue < 18
            ? colors.success
            : clampedValue < 30
                ? colors.warning
                : colors.error;

    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted),
          ),
        ),
        Expanded(
          child: Container(
            height: 6,
            decoration: BoxDecoration(
              color: colors.surfaceAlt,
              borderRadius: BorderRadius.circular(SkotiqTokens.radiusXs),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: measured ? clampedValue / 100.0 : 0.0,
              child: Container(
                decoration: BoxDecoration(
                  color: barColor,
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusXs),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 36,
          child: Text(
            measured ? clampedValue.toStringAsFixed(0) : '—',
            textAlign: TextAlign.right,
            style: SkotiqTypography.labelStrongSm.copyWith(color: barColor),
          ),
        ),
      ],
    );
  }
}

// Tilt assessment card

class _TiltAssessmentCard extends StatelessWidget {
  final OpticalTrainDiagnostics diagnostics;
  final SkotiqColors colors;

  const _TiltAssessmentCard({
    required this.diagnostics,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    final direction = diagnostics.dominantTiltDirection;
    final score = diagnostics.tiltScore;
    // A tilt penalty of 0 is the BEST possible score, so a session with no PSF
    // field tiles produced the same number as a perfectly flat field — and this
    // card badged it "Within range" and stated "tilt looks controlled for this
    // session" beside its own "0 tiles" panel. A user who came here suspecting
    // tilt read a green verdict and stopped investigating.
    final measured = diagnostics.tiltMeasured;
    final severity = !measured
        ? 'Not measured'
        : score >= 30
            ? 'Strong tilt'
            : score >= 18
                ? 'Watch tilt'
                : 'Within range';
    final severityColor = !measured
        ? colors.textMuted
        : score >= 30
            ? colors.error
            : score >= 18
                ? colors.warning
                : colors.success;

    return _DiagCard(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.move, size: 16, color: colors.primary),
              const SizedBox(width: 8),
              // See the matching note on the Collimation card: a fixed-width
              // title beside the widest badge overflows the 320 px column.
              Expanded(
                child: Text(
                  'Tilt',
                  overflow: TextOverflow.ellipsis,
                  style: SkotiqTypography.h5
                      .copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: severityColor.withValues(alpha: 0.15),
                  borderRadius:
                      BorderRadius.circular(SkotiqTokens.radiusInline4),
                ),
                child: Text(
                  severity,
                  style: SkotiqTypography.labelStrongSm
                      .copyWith(color: severityColor),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Tilt direction visualizer
          Center(
            child: SizedBox(
              width: 120,
              height: 120,
              child: CustomPaint(
                painter: _TiltDirectionPainter(
                  direction: direction,
                  magnitude: score,
                  arrowColor: severityColor,
                  ringColor: colors.border,
                  textColor: colors.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(
              direction == 'unknown'
                  ? 'Need more solved frames to determine tilt direction'
                  : 'Strongest tilt points toward $direction',
              style: TextStyle(
                  fontSize: SkotiqTypography.fontSize12,
                  color: colors.textSecondary),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text(
              !measured
                  ? 'No PSF field tiles for this session, so tilt was not '
                      'measured. Capture plate-solved frames with science '
                      'field metrics enabled.'
                  : score >= 30
                      ? 'Score ${score.toStringAsFixed(1)}: check tilt adjusters, focuser sag, or adapter seating.'
                      : score >= 18
                          ? 'Score ${score.toStringAsFixed(1)}: compare corners before making a mechanical change.'
                          : 'Score ${score.toStringAsFixed(1)}: tilt looks controlled for this session.',
              style: TextStyle(
                fontSize: SkotiqTypography.fontSize11,
                color: colors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
