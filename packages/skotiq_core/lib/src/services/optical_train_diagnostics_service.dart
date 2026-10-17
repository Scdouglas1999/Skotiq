import '../database/database.dart'
    show AstrometryResidualVectorRow, PsfFieldTileRow;

enum OpticalIssueSeverity { info, warning, critical }

class OpticalDiagnosticIssue {
  final String title;
  final String detail;
  final OpticalIssueSeverity severity;

  const OpticalDiagnosticIssue({
    required this.title,
    required this.detail,
    required this.severity,
  });
}

class OpticalTrainDiagnostics {
  final double tiltScore;
  final double collimationScore;
  final String dominantTiltDirection;
  final List<OpticalDiagnosticIssue> issues;

  /// Whether the PSF field map actually supported a tilt estimate.
  ///
  /// Callers must check this before treating a zero penalty as a flat field.
  final bool tiltMeasured;

  /// Whether the astrometric residuals supported an edge-versus-centre
  /// comparison. Needs samples on both sides of the split — with none, the
  /// centre denominator is a clamp floor rather than a measurement.
  final bool collimationMeasured;

  const OpticalTrainDiagnostics({
    required this.tiltScore,
    required this.collimationScore,
    required this.dominantTiltDirection,
    required this.issues,
    this.tiltMeasured = true,
    this.collimationMeasured = true,
  });

  bool get hasIssues => issues.isNotEmpty;

  /// Single source of truth for the A/B/C/D/F grade derived from this run.
  OpticalHealthScore get healthScore =>
      OpticalHealthScore.fromDiagnostics(this);
}

/// Letter grade buckets shared by the diagnostics screen and any analytics
/// surface that needs to summarise optical-train quality. Defined here so two
/// views never disagree about whether an 80/100 score is a "B" or a "C".
enum OpticalHealthGrade { a, b, c, d, f }

extension OpticalHealthGradeLabel on OpticalHealthGrade {
  String get letter {
    switch (this) {
      case OpticalHealthGrade.a:
        return 'A';
      case OpticalHealthGrade.b:
        return 'B';
      case OpticalHealthGrade.c:
        return 'C';
      case OpticalHealthGrade.d:
        return 'D';
      case OpticalHealthGrade.f:
        return 'F';
    }
  }

  String get qualityLabel {
    switch (this) {
      case OpticalHealthGrade.a:
        return 'Excellent';
      case OpticalHealthGrade.b:
        return 'Good';
      case OpticalHealthGrade.c:
        return 'Fair';
      case OpticalHealthGrade.d:
        return 'Poor';
      case OpticalHealthGrade.f:
        return 'Critical';
    }
  }
}

/// Shared optical-train health summary. Centralises the score → grade mapping
/// AND the per-axis severity thresholds so the diagnostics letter grade and
/// the per-card severity chips never drift apart. `tiltScore` and
/// `collimationScore` are penalties (lower is better, 0..100).
class OpticalHealthScore {
  final double tiltScore;
  final double collimationScore;
  final double overallScore;
  final OpticalHealthGrade grade;
  final OpticalIssueSeverity tiltSeverity;
  final OpticalIssueSeverity collimationSeverity;

  /// False when either axis had no data behind it, in which case [overallScore]
  /// and [grade] are placeholders and only [letterGrade] / [qualityLabel] are
  /// safe to show — they render as "not measured" rather than as an A.
  final bool isMeasured;

  // Penalty thresholds per axis. Kept here (not inlined in widgets) so the
  // diagnostics cards, KPI strips, and any future analytics view all bucket
  // identical raw numbers into identical ratings.
  static const double tiltWarnThreshold = 18.0;
  static const double tiltCriticalThreshold = 30.0;
  static const double collimationWarnThreshold = 15.0;
  static const double collimationCriticalThreshold = 25.0;

  // Letter-grade bands on the inverted overall score (higher is better).
  static const double aThreshold = 90.0;
  static const double bThreshold = 75.0;
  static const double cThreshold = 55.0;
  static const double dThreshold = 35.0;

  const OpticalHealthScore._({
    required this.tiltScore,
    required this.collimationScore,
    required this.overallScore,
    required this.grade,
    required this.tiltSeverity,
    required this.collimationSeverity,
    required this.isMeasured,
  });

  factory OpticalHealthScore.fromDiagnostics(OpticalTrainDiagnostics d) {
    return OpticalHealthScore.fromScores(
      tiltScore: d.tiltScore,
      collimationScore: d.collimationScore,
      // One grade covers both axes, so it is only a measurement when both are.
      isMeasured: d.tiltMeasured && d.collimationMeasured,
    );
  }

  factory OpticalHealthScore.fromScores({
    required double tiltScore,
    required double collimationScore,
    bool isMeasured = true,
  }) {
    final tiltPenalty = tiltScore.clamp(0.0, 100.0);
    final collPenalty = collimationScore.clamp(0.0, 100.0);
    // Equal-weight blend: tilt and spacing both contribute to field shape.
    final overall = (100.0 - (tiltPenalty * 0.5 + collPenalty * 0.5)).clamp(
      0.0,
      100.0,
    );
    return OpticalHealthScore._(
      tiltScore: tiltPenalty,
      collimationScore: collPenalty,
      overallScore: overall,
      grade: _gradeForOverall(overall),
      tiltSeverity: _severityFor(
        tiltPenalty,
        warnAt: tiltWarnThreshold,
        criticalAt: tiltCriticalThreshold,
      ),
      collimationSeverity: _severityFor(
        collPenalty,
        warnAt: collimationWarnThreshold,
        criticalAt: collimationCriticalThreshold,
      ),
      isMeasured: isMeasured,
    );
  }

  /// Grade label for display. An unmeasured train has no grade — reporting the
  /// A that a 0-penalty blend arithmetically produces told users their optics
  /// were excellent on the strength of no measurement at all.
  String get letterGrade => isMeasured ? grade.letter : '—';
  String get qualityLabel => isMeasured ? grade.qualityLabel : 'Not measured';

  static OpticalHealthGrade _gradeForOverall(double score) {
    if (score >= aThreshold) return OpticalHealthGrade.a;
    if (score >= bThreshold) return OpticalHealthGrade.b;
    if (score >= cThreshold) return OpticalHealthGrade.c;
    if (score >= dThreshold) return OpticalHealthGrade.d;
    return OpticalHealthGrade.f;
  }

  static OpticalIssueSeverity _severityFor(
    double penalty, {
    required double warnAt,
    required double criticalAt,
  }) {
    if (penalty >= criticalAt) return OpticalIssueSeverity.critical;
    if (penalty >= warnAt) return OpticalIssueSeverity.warning;
    return OpticalIssueSeverity.info;
  }
}

/// Converts science PSF and residual maps into imaging-train guidance.
class OpticalTrainDiagnosticsService {
  const OpticalTrainDiagnosticsService();

  OpticalTrainDiagnostics analyze({
    required List<PsfFieldTileRow> psfTiles,
    required List<AstrometryResidualVectorRow> residualVectors,
  }) {
    if (psfTiles.isEmpty) {
      return const OpticalTrainDiagnostics(
        tiltScore: 0,
        collimationScore: 0,
        dominantTiltDirection: 'unknown',
        tiltMeasured: false,
        collimationMeasured: false,
        issues: [
          OpticalDiagnosticIssue(
            title: 'No diagnostics data',
            detail:
                'Capture more solved frames to estimate field tilt and collimation.',
            severity: OpticalIssueSeverity.info,
          ),
        ],
      );
    }

    // Compare the OUTERMOST row/column on each side. Splitting the grid at its
    // midpoint instead put the centre band on one side of every comparison
    // (`>= mid` caught the middle column and row), which halved the apparent
    // deviation of the right and bottom edges: a tilt running mostly top-to-
    // bottom then scored lower on "bottom" than on "left" and the readout sent
    // the user to the wrong adjustment screw.
    final minCol = psfTiles
        .map((tile) => tile.tileCol)
        .reduce((a, b) => a < b ? a : b);
    final maxCol = psfTiles
        .map((tile) => tile.tileCol)
        .reduce((a, b) => a > b ? a : b);
    final minRow = psfTiles
        .map((tile) => tile.tileRow)
        .reduce((a, b) => a < b ? a : b);
    final maxRow = psfTiles
        .map((tile) => tile.tileRow)
        .reduce((a, b) => a > b ? a : b);

    final left = _mean(
      psfTiles.where((tile) => tile.tileCol == minCol).map((t) => t.medianHfr),
    );
    final right = _mean(
      psfTiles.where((tile) => tile.tileCol == maxCol).map((t) => t.medianHfr),
    );
    final top = _mean(
      psfTiles.where((tile) => tile.tileRow == minRow).map((t) => t.medianHfr),
    );
    final bottom = _mean(
      psfTiles.where((tile) => tile.tileRow == maxRow).map((t) => t.medianHfr),
    );
    final global = _mean(
      psfTiles.map((tile) => tile.medianHfr),
    ).clamp(0.1, 100.0);

    final horizontalTilt = (left - right).abs() / global;
    final verticalTilt = (top - bottom).abs() / global;
    final tiltScore =
        ((horizontalTilt > verticalTilt ? horizontalTilt : verticalTilt) * 100)
            .clamp(0.0, 100.0);
    // A gradient needs two positions to run between. With every tile in one
    // column and one row, left==right and top==bottom by construction, so the
    // resulting 0 says "the grid was 1x1", not "the field is flat".
    final tiltMeasured = maxCol > minCol || maxRow > minRow;

    final edgeSamples = residualVectors
        .where(
          (row) => row.x < 0.25 || row.x > 0.75 || row.y < 0.25 || row.y > 0.75,
        )
        .map((row) => row.magnitudeArcsec)
        .where((value) => value.isFinite)
        .toList(growable: false);
    final centerSamples = residualVectors
        .where(
          (row) =>
              row.x >= 0.25 && row.x <= 0.75 && row.y >= 0.25 && row.y <= 0.75,
        )
        .map((row) => row.magnitudeArcsec)
        .where((value) => value.isFinite)
        .toList(growable: false);
    // The score is a RATIO of edge to centre; with either side missing the
    // clamp below supplies the missing half and the answer is arithmetic, not
    // measurement — an empty residual table produced a confident "centre and
    // edge behaviour look balanced".
    final collimationMeasured =
        edgeSamples.isNotEmpty && centerSamples.isNotEmpty;
    final edgeResidual = _mean(edgeSamples);
    final centerResidual = _mean(centerSamples).clamp(0.1, 1000.0);
    final collimationScore =
        ((edgeResidual / centerResidual - 1.0).clamp(0.0, 2.0) * 50.0).clamp(
          0.0,
          100.0,
        );

    final dominantTiltDirection = _dominantTiltDirection(
      left: left,
      right: right,
      top: top,
      bottom: bottom,
      horizontalTilt: horizontalTilt,
      verticalTilt: verticalTilt,
    );

    final issues = <OpticalDiagnosticIssue>[
      if (tiltMeasured && tiltScore >= 18)
        OpticalDiagnosticIssue(
          title: 'Field tilt detected',
          detail:
              'PSF size is uneven across the frame. Strongest degradation is toward $dominantTiltDirection.',
          severity: tiltScore >= 30
              ? OpticalIssueSeverity.critical
              : OpticalIssueSeverity.warning,
        ),
      if (collimationMeasured && collimationScore >= 15)
        OpticalDiagnosticIssue(
          title: 'Collimation or spacing mismatch',
          detail:
              'Astrometric residuals grow toward the field edge. Inspect backfocus spacing and primary/secondary alignment.',
          severity: collimationScore >= 25
              ? OpticalIssueSeverity.critical
              : OpticalIssueSeverity.warning,
        ),
      // Name what was NOT measured instead of letting the "looks stable" line
      // below silently vouch for it.
      if (!tiltMeasured)
        const OpticalDiagnosticIssue(
          title: 'Tilt not measured',
          detail:
              'PSF tiles cover a single row and column, so there is no across-field gradient to compare.',
          severity: OpticalIssueSeverity.info,
        ),
      if (!collimationMeasured)
        const OpticalDiagnosticIssue(
          title: 'Collimation not measured',
          detail:
              'This session has no astrometric residuals on both sides of the field, so edge-versus-centre behaviour could not be compared.',
          severity: OpticalIssueSeverity.info,
        ),
      if (tiltMeasured &&
          collimationMeasured &&
          tiltScore < 18 &&
          collimationScore < 15)
        const OpticalDiagnosticIssue(
          title: 'Optical train looks stable',
          detail:
              'Field HFR and residual patterns are balanced across the image.',
          severity: OpticalIssueSeverity.info,
        ),
    ];

    return OpticalTrainDiagnostics(
      tiltScore: tiltScore,
      collimationScore: collimationScore,
      dominantTiltDirection: tiltMeasured ? dominantTiltDirection : 'unknown',
      tiltMeasured: tiltMeasured,
      collimationMeasured: collimationMeasured,
      issues: issues,
    );
  }

  /// The edge the field gradient actually runs towards.
  ///
  /// Decided on the same axis comparison that sets [tiltScore], so the reported
  /// direction can never disagree with the score: pick the steeper axis first,
  /// then the worse side of that axis. Ranking the four edge means against each
  /// other instead let a shallow horizontal gradient outrank a steeper vertical
  /// one whenever the horizontal edge happened to sit higher in absolute HFR.
  String _dominantTiltDirection({
    required double left,
    required double right,
    required double top,
    required double bottom,
    required double horizontalTilt,
    required double verticalTilt,
  }) {
    if (horizontalTilt >= verticalTilt) {
      return left >= right ? 'left edge' : 'right edge';
    }
    return top >= bottom ? 'top edge' : 'bottom edge';
  }

  double _mean(Iterable<double> values) {
    final list = values
        .where((value) => value.isFinite)
        .toList(growable: false);
    if (list.isEmpty) {
      return 0.0;
    }
    return list.reduce((a, b) => a + b) / list.length;
  }
}
