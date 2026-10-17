import 'dart:convert';

import '../../database/database.dart' as db;
import '../../models/imaging/imaging_models.dart' show ImageStats;

/// Thresholds for automatic or bulk frame rejection.
///
/// A `null` field means "do not grade on this dimension". This is shared by
/// the interactive Image Grader dialog and the capture-time auto-grader so
/// both paths enforce identical rules.
class FrameGradeRules {
  final double? maxHfr;
  final double? maxFwhm;
  final double? maxEccentricity;
  final int? minStars;
  final double? maxGuidingRmsTotalArcsec;

  const FrameGradeRules({
    this.maxHfr,
    this.maxFwhm,
    this.maxEccentricity,
    this.minStars,
    this.maxGuidingRmsTotalArcsec,
  });

  /// Conservative defaults used when auto-grading is enabled but the user has
  /// not opened the grader to customise thresholds yet.
  static const conservativeDefaults = FrameGradeRules(
    maxHfr: 3.2,
    minStars: 25,
    maxGuidingRmsTotalArcsec: 1.2,
  );

  bool get isEmpty =>
      maxHfr == null &&
      maxFwhm == null &&
      maxEccentricity == null &&
      minStars == null &&
      maxGuidingRmsTotalArcsec == null;

  /// Whether any rule is active. Convenience inverse of [isEmpty] so callers
  /// (e.g. the live per-sub badge) can cheaply skip grading work entirely when
  /// no thresholds are configured.
  bool get hasActiveRules => !isEmpty;

  /// Rejection reason for a frame whose star detector ran and found nothing.
  ///
  /// A measured zero is a rejection because all other star-derived thresholds
  /// are unavailable. `null` remains distinct and means no detector ran. Keep
  /// this text aligned with the native grader's persisted reason.
  static const _unmeasurableFrameReason =
      'no stars detected — frame quality is unmeasurable '
      '(clouds, trailing, off-target slew, or an obstructed aperture)';

  FrameGradeRules copyWith({
    double? maxHfr,
    bool clearHfr = false,
    double? maxFwhm,
    bool clearFwhm = false,
    double? maxEccentricity,
    bool clearEccentricity = false,
    int? minStars,
    bool clearStars = false,
    double? maxGuidingRmsTotalArcsec,
    bool clearGuiding = false,
  }) {
    return FrameGradeRules(
      maxHfr: clearHfr ? null : (maxHfr ?? this.maxHfr),
      maxFwhm: clearFwhm ? null : (maxFwhm ?? this.maxFwhm),
      maxEccentricity: clearEccentricity
          ? null
          : (maxEccentricity ?? this.maxEccentricity),
      minStars: clearStars ? null : (minStars ?? this.minStars),
      maxGuidingRmsTotalArcsec: clearGuiding
          ? null
          : (maxGuidingRmsTotalArcsec ?? this.maxGuidingRmsTotalArcsec),
    );
  }

  /// Returns a rejection reason when the frame fails any active rule.
  ///
  /// HFR, star count and guiding RMS live directly on the [db.CapturedImage]
  /// data class and are read from it. Eccentricity and FWHM do **not**: the
  /// generated `CapturedImage` data class carries neither field (eccentricity
  /// is a raw-DDL column added by the v30 migration but never declared on the
  /// Drift table; FWHM is not persisted on `captured_images` at all). They are
  /// therefore supplied by the caller via [eccentricity] / [fwhm], exactly the
  /// way [gradeStats] takes its out-of-band metrics.
  ///
  /// **What [eccentricity] must be**: the per-frame median star eccentricity
  /// the native grader graded on — the `captured_images.eccentricity` column,
  /// stamped from `ImageStats.eccentricity` by the imaging persistence path.
  /// That is the number that decided which folder the file is in, so grading
  /// on anything else is how the badge and the on-disk grade end up
  /// contradicting each other on the same frame. A PSF field-map tile median
  /// is *not* that number: it is a later, optional, per-tile computation that
  /// is absent whenever the science stage did not run and that is measured
  /// from a different, narrower star population.
  ///
  /// A `null` metric means "cannot grade this dimension" and the rule is
  /// skipped — a frame whose science pipeline produced no PSF data (stage
  /// disabled, starless field) is legitimately ungradeable on these two
  /// dimensions and must never be rejected without evidence. A *measured*
  /// `starCount` of zero is the one exception and rejects outright; see
  /// [_unmeasurableFrameReason].
  String? gradeFrame(
    db.CapturedImage img, {
    double? eccentricity,
    double? fwhm,
  }) {
    // Mirrors the native grader's `check.is_active()` early-out: with no
    // thresholds configured nothing is graded at all, including the
    // zero-star rule below.
    if (isEmpty) return null;
    if (img.starCount == 0) return 'Auto-grade: $_unmeasurableFrameReason';

    final reasons = <String>[];
    if (maxHfr != null && img.hfr != null && img.hfr! > maxHfr!) {
      reasons.add(
        'HFR ${img.hfr!.toStringAsFixed(2)} > ${maxHfr!.toStringAsFixed(2)}',
      );
    }
    if (maxFwhm != null && fwhm != null && fwhm > maxFwhm!) {
      reasons.add(
        'FWHM ${fwhm.toStringAsFixed(2)} > ${maxFwhm!.toStringAsFixed(2)}',
      );
    }
    if (maxEccentricity != null &&
        eccentricity != null &&
        eccentricity > maxEccentricity!) {
      reasons.add(
        'Eccentricity ${eccentricity.toStringAsFixed(2)} > ${maxEccentricity!.toStringAsFixed(2)}',
      );
    }
    if (minStars != null &&
        img.starCount != null &&
        img.starCount! < minStars!) {
      reasons.add('Stars ${img.starCount} < $minStars');
    }
    if (maxGuidingRmsTotalArcsec != null &&
        img.guidingRmsTotal != null &&
        img.guidingRmsTotal! > maxGuidingRmsTotalArcsec!) {
      reasons.add(
        'Guiding ${img.guidingRmsTotal!.toStringAsFixed(2)}" > ${maxGuidingRmsTotalArcsec!.toStringAsFixed(2)}"',
      );
    }
    return reasons.isEmpty ? null : 'Auto-grade: ${reasons.join('; ')}';
  }

  /// Grades an in-memory [ImageStats] snapshot using the identical thresholds
  /// and reason-string format as [gradeFrame], so the live per-sub badge and
  /// the persisted auto-grader never disagree (there is exactly one rule
  /// engine).
  ///
  /// [ImageStats] now carries a per-frame [ImageStats.eccentricity] (measured
  /// by the native star detector from star shape moments), so the gate reads
  /// it directly. Guiding RMS still lives outside the stats snapshot and is
  /// supplied via [guidingRmsTotal] from live telemetry. The optional
  /// [eccentricity] argument overrides [ImageStats.eccentricity] when a caller
  /// has a more authoritative value (e.g. the persisted science row); when
  /// omitted the engine falls back to the live measured value. As in
  /// [gradeFrame], a `null` metric means "cannot grade this dimension" and that
  /// rule is skipped — never a no-evidence reject — while a measured
  /// `starCount` of zero rejects outright (see [_unmeasurableFrameReason]).
  String? gradeStats(
    ImageStats stats, {
    double? guidingRmsTotal,
    double? eccentricity,
  }) {
    if (isEmpty) return null;
    if (stats.starCount == 0) return 'Auto-grade: $_unmeasurableFrameReason';

    final reasons = <String>[];
    // Caller override wins; otherwise use the live measured frame value.
    final effectiveEccentricity = eccentricity ?? stats.eccentricity;
    if (maxHfr != null && stats.hfr != null && stats.hfr! > maxHfr!) {
      reasons.add(
        'HFR ${stats.hfr!.toStringAsFixed(2)} > ${maxHfr!.toStringAsFixed(2)}',
      );
    }
    if (maxFwhm != null && stats.fwhm != null && stats.fwhm! > maxFwhm!) {
      reasons.add(
        'FWHM ${stats.fwhm!.toStringAsFixed(2)} > ${maxFwhm!.toStringAsFixed(2)}',
      );
    }
    if (maxEccentricity != null &&
        effectiveEccentricity != null &&
        effectiveEccentricity > maxEccentricity!) {
      reasons.add(
        'Eccentricity ${effectiveEccentricity.toStringAsFixed(2)} > ${maxEccentricity!.toStringAsFixed(2)}',
      );
    }
    if (minStars != null &&
        stats.starCount != null &&
        stats.starCount! < minStars!) {
      reasons.add('Stars ${stats.starCount} < $minStars');
    }
    if (maxGuidingRmsTotalArcsec != null &&
        guidingRmsTotal != null &&
        guidingRmsTotal > maxGuidingRmsTotalArcsec!) {
      reasons.add(
        'Guiding ${guidingRmsTotal.toStringAsFixed(2)}" > ${maxGuidingRmsTotalArcsec!.toStringAsFixed(2)}"',
      );
    }
    return reasons.isEmpty ? null : 'Auto-grade: ${reasons.join('; ')}';
  }

  Map<String, dynamic> toJson() => {
    if (maxHfr != null) 'maxHfr': maxHfr,
    if (maxFwhm != null) 'maxFwhm': maxFwhm,
    if (maxEccentricity != null) 'maxEccentricity': maxEccentricity,
    if (minStars != null) 'minStars': minStars,
    if (maxGuidingRmsTotalArcsec != null)
      'maxGuidingRmsTotalArcsec': maxGuidingRmsTotalArcsec,
  };

  static FrameGradeRules? fromJsonString(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return FrameGradeRules(
        maxHfr: (map['maxHfr'] as num?)?.toDouble(),
        maxFwhm: (map['maxFwhm'] as num?)?.toDouble(),
        maxEccentricity: (map['maxEccentricity'] as num?)?.toDouble(),
        minStars: (map['minStars'] as num?)?.toInt(),
        maxGuidingRmsTotalArcsec: (map['maxGuidingRmsTotalArcsec'] as num?)
            ?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  String toJsonString() => jsonEncode(toJson());

  /// Suggest thresholds from session statistics (75th percentile for max
  /// metrics, 25th for min stars).
  static FrameGradeRules suggestFrom(List<db.CapturedImage> frames) {
    final hfrs =
        frames
            .map((f) => f.hfr)
            .whereType<double>()
            .where((v) => v.isFinite)
            .toList()
          ..sort();
    final stars = frames.map((f) => f.starCount).whereType<int>().toList()
      ..sort();
    final gd =
        frames
            .map((f) => f.guidingRmsTotal)
            .whereType<double>()
            .where((v) => v.isFinite)
            .toList()
          ..sort();

    double? p75d(List<double> xs) => xs.isEmpty
        ? null
        : xs[(xs.length * 0.75).floor().clamp(0, xs.length - 1)];
    int? p25i(List<int> xs) => xs.isEmpty
        ? null
        : xs[(xs.length * 0.25).floor().clamp(0, xs.length - 1)];

    return FrameGradeRules(
      maxHfr: p75d(hfrs),
      minStars: p25i(stars),
      maxGuidingRmsTotalArcsec: p75d(gd),
    );
  }
}
