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

  /// Mean star size in the corner tiles divided by the mean in the inner
  /// tiles: 1.0 is a flat field, 1.25 means the corners are 25% softer on
  /// every side, which is field curvature or corrector spacing rather than
  /// tilt. Null when the grid has no inner tiles or too few corner or inner
  /// tiles held stars.
  final double? cornerToCenterRatio;

  const OpticalTrainDiagnostics({
    required this.tiltScore,
    required this.collimationScore,
    required this.dominantTiltDirection,
    required this.issues,
    this.tiltMeasured = true,
    this.collimationMeasured = true,
    this.cornerToCenterRatio,
  });

  bool get curvatureMeasured => cornerToCenterRatio != null;

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

  /// A tile needs this many stars before its median star size counts. A
  /// tile with no stars (a tree, a dark corner, a sparse field) stores a
  /// star size of 0, which is no measurement at all.
  static const int minTileStars = 3;

  /// Corners this much softer than the inner field are reported as field
  /// curvature or spacing.
  static const double curvatureWarnRatio = 1.10;
  static const double curvatureCriticalRatio = 1.30;

  /// Residual vectors per frame needed to locate the frame's extent when
  /// the vectors are stored in pixels.
  static const int _minVectorsPerFrame = 8;

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

    // The grid's outer rows and columns come from every tile, measured or
    // not, so an empty edge stays an edge rather than moving the comparison
    // inward.
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

    // Star size only from tiles that measured one.
    bool measured(PsfFieldTileRow tile) =>
        tile.starCount >= minTileStars &&
        tile.medianHfr.isFinite &&
        tile.medianHfr > 0;
    final valid = psfTiles.where(measured).toList(growable: false);

    // An edge is measured when at least half of its tiles held stars.
    double? edge(bool Function(PsfFieldTileRow) onEdge) {
      final all = psfTiles.where(onEdge).length;
      final hfrs = valid.where(onEdge).map((t) => t.medianHfr).toList();
      final enough = hfrs.isNotEmpty && hfrs.length * 2 >= all;
      return enough ? _mean(hfrs) : null;
    }

    final left = edge((t) => t.tileCol == minCol);
    final right = edge((t) => t.tileCol == maxCol);
    final top = edge((t) => t.tileRow == minRow);
    final bottom = edge((t) => t.tileRow == maxRow);
    final global = valid.isEmpty
        ? 0.1
        : _mean(valid.map((tile) => tile.medianHfr)).clamp(0.1, 100.0);

    // A gradient needs two positions to run between and a measurement at
    // each end.
    final horizontalMeasured = maxCol > minCol && left != null && right != null;
    final verticalMeasured = maxRow > minRow && top != null && bottom != null;
    final tiltMeasured = horizontalMeasured || verticalMeasured;
    final horizontalTilt = horizontalMeasured
        ? (left - right).abs() / global
        : 0.0;
    final verticalTilt = verticalMeasured
        ? (top - bottom).abs() / global
        : 0.0;
    final tiltScore =
        ((horizontalTilt > verticalTilt ? horizontalTilt : verticalTilt) * 100)
            .clamp(0.0, 100.0);

    // Field curvature: the corners against the inner tiles. A symmetric
    // softening cancels in every edge-against-edge difference above, so it
    // needs its own term.
    final cornerHfrs = valid
        .where(
          (t) =>
              (t.tileRow == minRow || t.tileRow == maxRow) &&
              (t.tileCol == minCol || t.tileCol == maxCol),
        )
        .map((t) => t.medianHfr)
        .toList(growable: false);
    final innerHfrs = valid
        .where(
          (t) =>
              t.tileRow > minRow &&
              t.tileRow < maxRow &&
              t.tileCol > minCol &&
              t.tileCol < maxCol,
        )
        .map((t) => t.medianHfr)
        .toList(growable: false);
    final double? cornerToCenterRatio =
        cornerHfrs.length >= 2 && innerHfrs.isNotEmpty
        ? _mean(cornerHfrs) / _mean(innerHfrs)
        : null;
    final curvatureFlagged =
        cornerToCenterRatio != null &&
        cornerToCenterRatio >= curvatureWarnRatio;

    // Residual positions are compared in fractions of the frame. Vectors
    // stored in pixels are scaled by the extent of their own frame's
    // vectors, which come from catalog matches spread over the whole field.
    final normalized = _normalizedResiduals(residualVectors);
    bool inCenter(({double x, double y, double magnitude}) v) =>
        v.x >= 0.25 && v.x <= 0.75 && v.y >= 0.25 && v.y <= 0.75;
    final edgeSamples = normalized
        .where((v) => !inCenter(v))
        .map((v) => v.magnitude)
        .toList(growable: false);
    final centerSamples = normalized
        .where(inCenter)
        .map((v) => v.magnitude)
        .toList(growable: false);
    // The score is a RATIO of edge to centre; with either side missing the
    // clamp below supplies the missing half and the answer is arithmetic, not
    // measurement.
    final collimationMeasured =
        edgeSamples.isNotEmpty && centerSamples.isNotEmpty;
    final edgeResidual = _mean(edgeSamples);
    final centerResidual = _mean(centerSamples).clamp(0.1, 1000.0);
    final collimationScore =
        ((edgeResidual / centerResidual - 1.0).clamp(0.0, 2.0) * 50.0).clamp(
          0.0,
          100.0,
        );

    // The direction comes from the axis that set the score, then the worse
    // side of that axis, so it can never disagree with the score.
    final dominantTiltDirection = !tiltMeasured
        ? 'unknown'
        : horizontalTilt >= verticalTilt && horizontalMeasured
        ? (left >= right ? 'left edge' : 'right edge')
        : (top! >= bottom! ? 'top edge' : 'bottom edge');

    final softerPercent = cornerToCenterRatio == null
        ? 0
        : ((cornerToCenterRatio - 1.0) * 100).round();
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
      if (curvatureFlagged)
        OpticalDiagnosticIssue(
          title: 'Corners are $softerPercent% softer than the center',
          detail:
              'Stars grow toward every corner, not toward one side. That points to field curvature or the spacing between the corrector or flattener and the sensor, not to tilt.',
          severity: cornerToCenterRatio >= curvatureCriticalRatio
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
              'Too few PSF tiles along opposite edges of the frame held stars, so there is no across-field gradient to compare.',
          severity: OpticalIssueSeverity.info,
        ),
      if (cornerToCenterRatio == null)
        const OpticalDiagnosticIssue(
          title: 'Field curvature not measured',
          detail:
              'Too few corner or inner PSF tiles held stars to compare the corners with the center.',
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
          cornerToCenterRatio != null &&
          !curvatureFlagged &&
          tiltScore < 18 &&
          collimationScore < 15)
        const OpticalDiagnosticIssue(
          title: 'Optical train looks stable',
          detail:
              'Star size is even from side to side and from center to corner, and residuals do not grow toward the edges.',
          severity: OpticalIssueSeverity.info,
        ),
    ];

    return OpticalTrainDiagnostics(
      tiltScore: tiltScore,
      collimationScore: collimationScore,
      dominantTiltDirection: dominantTiltDirection,
      tiltMeasured: tiltMeasured,
      collimationMeasured: collimationMeasured,
      cornerToCenterRatio: cornerToCenterRatio,
      issues: issues,
    );
  }

  /// Residual vectors with positions as fractions of their frame.
  ///
  /// Positions already within 0..1 are taken as fractions. Pixel positions
  /// are scaled by the extent of the same frame's vectors; a frame with too
  /// few vectors to span the field is left out.
  List<({double x, double y, double magnitude})> _normalizedResiduals(
    List<AstrometryResidualVectorRow> rows,
  ) {
    final byFrame = <int?, List<AstrometryResidualVectorRow>>{};
    for (final row in rows) {
      if (!row.x.isFinite || !row.y.isFinite) continue;
      if (!row.magnitudeArcsec.isFinite) continue;
      byFrame.putIfAbsent(row.capturedImageId, () => []).add(row);
    }
    final out = <({double x, double y, double magnitude})>[];
    for (final frame in byFrame.values) {
      final inFractions = frame.every(
        (r) => r.x >= 0 && r.x <= 1 && r.y >= 0 && r.y <= 1,
      );
      if (inFractions) {
        out.addAll(
          frame.map((r) => (x: r.x, y: r.y, magnitude: r.magnitudeArcsec)),
        );
        continue;
      }
      if (frame.length < _minVectorsPerFrame) continue;
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final r in frame) {
        if (r.x < minX) minX = r.x;
        if (r.x > maxX) maxX = r.x;
        if (r.y < minY) minY = r.y;
        if (r.y > maxY) maxY = r.y;
      }
      final spanX = maxX - minX;
      final spanY = maxY - minY;
      if (spanX <= 0 || spanY <= 0) continue;
      out.addAll(
        frame.map(
          (r) => (
            x: (r.x - minX) / spanX,
            y: (r.y - minY) / spanY,
            magnitude: r.magnitudeArcsec,
          ),
        ),
      );
    }
    return out;
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
