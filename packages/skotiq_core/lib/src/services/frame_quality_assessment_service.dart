import 'dart:math' as math;

import '../database/database.dart' show CapturedImage;

/// Advisory quality level for a captured frame.
///
/// This is informational only. It does not delete files or modify the capture.
enum FrameQualityLevel { good, needsReview, poor }

enum FrameQualityDisposition { keep, review, autoReject }

/// How the assessor should treat its own "auto-reject" recommendation.
///
/// The score behind the recommendation is a hand-tuned heuristic, not a
/// trained model (see [FrameQualityAssessmentService.computeHeuristicScore]),
/// so escalating it to a rejection is the operator's choice:
///
/// - [off]      The heuristic is computed and surfaced but never escalates the
///              disposition beyond `keep` / `review`.
/// - [advisory] (default) Flagged frames are surfaced as `review` with a
///              reason; the disposition never becomes `autoReject`. The user
///              or a sequencer rule makes the reject decision.
/// - [auto]     Heuristic score >= 0.88 (or severe issues plus a very low
///              advisory score) flips the disposition to `autoReject`.
enum FrameGradingMode { off, advisory, auto }

/// Result of quality assessment for a single frame.
class FrameQualityAssessment {
  final FrameQualityLevel level;

  /// The frame's [recordedQualityScore] (or a 75 default) after every review
  /// penalty the assessor applied. This is the number the gallery tile shows,
  /// and it is NOT the score the database keeps — see [scoreExplanation].
  final double advisoryScore;

  /// `captured_images.quality_score` as recorded at capture time, or null when
  /// the frame was never scored.
  final double? recordedQualityScore;

  /// Heuristic score in [0, 1] computed by [FrameQualityAssessmentService].
  ///
  /// This is a hand-tuned logistic over HFR, guiding RMS, star count and
  /// the existing quality score. It is NOT a trained model; see
  /// [FrameQualityAssessmentService.computeHeuristicScore] for the exact
  /// coefficients and weighting.
  final double heuristicScore;
  final FrameQualityDisposition disposition;
  final List<String> reasons;

  const FrameQualityAssessment({
    required this.level,
    required this.advisoryScore,
    this.recordedQualityScore,
    this.heuristicScore = 0.5,
    this.disposition = FrameQualityDisposition.keep,
    required this.reasons,
  });

  bool get needsReview => level != FrameQualityLevel.good;
  bool get autoRejectCandidate =>
      disposition == FrameQualityDisposition.autoReject;

  String get label {
    switch (level) {
      case FrameQualityLevel.good:
        return 'Good';
      case FrameQualityLevel.needsReview:
        return 'Needs Review';
      case FrameQualityLevel.poor:
        return 'Poor';
    }
  }

  /// The verdict and its observations as one sentence.
  ///
  /// [reasons] holds every observation the assessor made, including ones that
  /// cost points without moving the verdict. Joining them onto the label with a
  /// dash therefore produced "Good — Low star count (39)" on a clean session:
  /// the dash-clause reads as the reason FOR the grade, so the app contradicted
  /// its own verdict. A frame that passed says so before it lists what it noted.
  String get summaryLine {
    if (reasons.isEmpty) return label;
    if (level == FrameQualityLevel.good) {
      return '$label — noted but not disqualifying: ${reasons.join('; ')}';
    }
    return '$label — ${reasons.join('; ')}';
  }

  /// Where [advisoryScore] came from, so the tile's number and the database's
  /// number are never two anonymous "scores" for one frame.
  String get scoreExplanation {
    final advisory = advisoryScore.toStringAsFixed(0);
    final recorded = recordedQualityScore;
    if (recorded == null) {
      return 'Advisory $advisory/100 — this frame has no recorded quality '
          'score, so review started from the 75 default'
          '${reasons.isEmpty ? '' : ' and subtracted the notes above'}.';
    }
    final base = recorded.toStringAsFixed(0);
    if (advisory == base) {
      return 'Advisory $advisory/100 — the recorded quality score ($base) with '
          'nothing subtracted.';
    }
    return 'Advisory $advisory/100 — the recorded quality score ($base) minus '
        'the review penalties listed above.';
  }
}

/// Summary counts for a set of assessed frames.
class FrameQualitySummary {
  final int total;
  final int good;
  final int needsReview;
  final int poor;

  const FrameQualitySummary({
    required this.total,
    required this.good,
    required this.needsReview,
    required this.poor,
  });
}

/// Provides non-destructive frame quality assessment.
///
/// The service classifies frames for user guidance. It never deletes files and
/// does not change frame acceptance flags.
class FrameQualityAssessmentService {
  /// How aggressively the service is allowed to escalate its own
  /// recommendation. Defaults to [FrameGradingMode.advisory]: the heuristic is
  /// shown but the user owns the reject decision. A user who explicitly chooses
  /// [FrameGradingMode.auto] gets automatic grading.
  final FrameGradingMode gradingMode;

  const FrameQualityAssessmentService({
    this.gradingMode = FrameGradingMode.advisory,
  });

  /// Assess a single frame with optional reference medians from the session.
  FrameQualityAssessment assessFrame(
    CapturedImage image, {
    double? referenceHfr,
    double? referenceGuidingRms,
  }) {
    var advisoryScore = image.qualityScore ?? 75.0;
    var severeIssue = false;
    var moderateIssueCount = 0;
    final reasons = <String>[];

    final hfr = image.hfr;
    if (hfr != null) {
      if (hfr >= 4.5) {
        advisoryScore -= 25;
        severeIssue = true;
        reasons.add('Very soft stars (HFR ${hfr.toStringAsFixed(2)} px)');
      } else if (hfr >= 3.5) {
        advisoryScore -= 12;
        moderateIssueCount++;
        reasons.add('Soft stars (HFR ${hfr.toStringAsFixed(2)} px)');
      }

      if (referenceHfr != null && referenceHfr > 0) {
        final ratio = hfr / referenceHfr;
        if (ratio >= 1.8) {
          advisoryScore -= 20;
          severeIssue = true;
          reasons.add('HFR is ${ratio.toStringAsFixed(1)}x session median');
        } else if (ratio >= 1.4) {
          advisoryScore -= 10;
          moderateIssueCount++;
          reasons.add('HFR above session median');
        }
      }
    }

    final starCount = image.starCount;
    if (starCount != null) {
      if (starCount < 20) {
        advisoryScore -= 20;
        severeIssue = true;
        reasons.add('Very low star count ($starCount)');
      } else if (starCount < 50) {
        advisoryScore -= 10;
        moderateIssueCount++;
        reasons.add('Low star count ($starCount)');
      }
    }

    final guidingRms = image.guidingRmsTotal;
    if (guidingRms != null) {
      if (guidingRms >= 3.0) {
        advisoryScore -= 20;
        severeIssue = true;
        reasons.add('High guiding RMS (${guidingRms.toStringAsFixed(2)}")');
      } else if (guidingRms >= 2.0) {
        advisoryScore -= 10;
        moderateIssueCount++;
        reasons.add('Elevated guiding RMS (${guidingRms.toStringAsFixed(2)}")');
      }

      if (referenceGuidingRms != null && referenceGuidingRms > 0) {
        final ratio = guidingRms / referenceGuidingRms;
        if (ratio >= 1.8) {
          advisoryScore -= 10;
          moderateIssueCount++;
          reasons.add('Guiding RMS spike vs session baseline');
        }
      }
    }

    final qualityScore = image.qualityScore;
    if (qualityScore != null) {
      if (qualityScore < 40) {
        advisoryScore -= 15;
        severeIssue = true;
        reasons.add('Low quality score (${qualityScore.toStringAsFixed(0)})');
      } else if (qualityScore < 60) {
        advisoryScore -= 8;
        moderateIssueCount++;
        reasons.add('Quality score below typical range');
      }
    }

    advisoryScore = advisoryScore.clamp(0.0, 100.0);

    final heuristicScore = computeHeuristicScore(
      image,
      referenceHfr: referenceHfr,
      referenceGuidingRms: referenceGuidingRms,
    );

    final level = severeIssue || advisoryScore < 45 || heuristicScore >= 0.82
        ? FrameQualityLevel.poor
        : (advisoryScore < 70 ||
              moderateIssueCount >= 2 ||
              heuristicScore >= 0.58)
        ? FrameQualityLevel.needsReview
        : FrameQualityLevel.good;

    // Never flag a frame without saying why.
    //
    // Every `reasons` entry above comes from a THRESHOLD being crossed, but a
    // frame can be demoted by the score alone: `advisoryScore` starts at the
    // frame's own `qualityScore`, so a frame that trips no individual threshold
    // and merely scores in the 60s still lands in `needsReview` with an EMPTY
    // reason list. The gallery then labels it "Needs Review" and offers the
    // operator nothing to act on — observed on real captures scoring 64-66 with
    // healthy HFR (2.5px) and 200 stars. State the composite instead.
    if (level != FrameQualityLevel.good && reasons.isEmpty) {
      reasons.add(
        'Composite quality ${advisoryScore.toStringAsFixed(0)}/100 is below the '
        'good-frame threshold, though no single measurement is out of range',
      );
    }

    final wouldAutoReject =
        heuristicScore >= 0.88 || (severeIssue && advisoryScore < 35);

    // Audit only the legacy `auto` mode escalates to
    // autoReject. Advisory mode (default) surfaces the recommendation
    // as a review-level reason but leaves the disposition to the user.
    final FrameQualityDisposition disposition;
    switch (gradingMode) {
      case FrameGradingMode.auto:
        disposition = wouldAutoReject
            ? FrameQualityDisposition.autoReject
            : level == FrameQualityLevel.needsReview ||
                  level == FrameQualityLevel.poor
            ? FrameQualityDisposition.review
            : FrameQualityDisposition.keep;
        break;
      case FrameGradingMode.advisory:
        disposition =
            wouldAutoReject ||
                level == FrameQualityLevel.needsReview ||
                level == FrameQualityLevel.poor
            ? FrameQualityDisposition.review
            : FrameQualityDisposition.keep;
        break;
      case FrameGradingMode.off:
        disposition =
            level == FrameQualityLevel.poor ||
                level == FrameQualityLevel.needsReview
            ? FrameQualityDisposition.review
            : FrameQualityDisposition.keep;
        break;
    }

    // Surface why the heuristic flagged the frame so the user can decide.
    if (wouldAutoReject && gradingMode != FrameGradingMode.off) {
      final note = gradingMode == FrameGradingMode.auto
          ? 'Quality heuristic suggests this frame should be auto-rejected.'
          : 'Quality heuristic flagged this frame for review (advisory only).';
      if (!reasons.any((reason) => reason.startsWith('Quality heuristic'))) {
        reasons.add(note);
      }
    }

    return FrameQualityAssessment(
      level: level,
      advisoryScore: advisoryScore,
      recordedQualityScore: image.qualityScore,
      heuristicScore: heuristicScore,
      disposition: disposition,
      reasons: reasons,
    );
  }

  /// Assess all frames in a set using session medians as reference points.
  Map<int, FrameQualityAssessment> assessBatch(Iterable<CapturedImage> images) {
    final list = images.toList();
    final medianHfr = _median(
      list.map((i) => i.hfr).whereType<double>().where((v) => v > 0),
    );
    final medianGuidingRms = _median(
      list
          .map((i) => i.guidingRmsTotal)
          .whereType<double>()
          .where((v) => v > 0),
    );

    return {
      for (final image in list)
        image.id: assessFrame(
          image,
          referenceHfr: medianHfr,
          referenceGuidingRms: medianGuidingRms,
        ),
    };
  }

  /// Build counts for dashboard and session overview display.
  FrameQualitySummary summarize(Map<int, FrameQualityAssessment> assessments) {
    var good = 0;
    var review = 0;
    var poor = 0;

    for (final assessment in assessments.values) {
      switch (assessment.level) {
        case FrameQualityLevel.good:
          good++;
          break;
        case FrameQualityLevel.needsReview:
          review++;
          break;
        case FrameQualityLevel.poor:
          poor++;
          break;
      }
    }

    return FrameQualitySummary(
      total: assessments.length,
      good: good,
      needsReview: review,
      poor: poor,
    );
  }

  double? _median(Iterable<double> values) {
    final sorted = values.toList()..sort();
    if (sorted.isEmpty) return null;

    final middle = sorted.length ~/ 2;
    if (sorted.length.isOdd) {
      return sorted[middle];
    }

    return (sorted[middle - 1] + sorted[middle]) / 2.0;
  }

  /// Compute a heuristic quality score in [0, 1] for a frame.
  ///
  /// This is NOT a trained model: it is a hand-tuned logistic with hardcoded
  /// coefficients, identical across all cameras and telescopes. There is no
  /// labelled training data, no per-camera calibration, and no fit procedure
  /// behind the coefficients — they were picked by hand to roughly track "this
  /// frame looks bad".
  ///
  /// Inputs (with fallbacks when the metric is missing):
  ///   - HFR ratio       = hfr / referenceHfr (or hfr / 2.6 px baseline)
  ///   - guiding ratio   = guidingRms / referenceGuidingRms (or / 1.4")
  ///   - star penalty    = 1 - (clamp(starCount, 20, 160) - 20) / 140
  ///   - quality penalty = 1 - clamp(qualityScore, 0, 100) / 100
  ///
  /// Formula:
  ///   logit = -2.9
  ///         + (hfrRatio       - 1.0) * 2.2
  ///         + (guidingRatio   - 1.0) * 1.6
  ///         +  starPenalty           * 1.8
  ///         +  qualityPenalty        * 2.4
  ///   score = 1 / (1 + exp(-logit))
  ///
  /// Higher scores indicate a "worse" frame in the heuristic's opinion.
  /// Treat this as a sorting aid, not a verdict. Use [FrameGradingMode]
  /// to control whether the score is allowed to escalate disposition.
  double computeHeuristicScore(
    CapturedImage image, {
    double? referenceHfr,
    double? referenceGuidingRms,
  }) {
    final hfr = image.hfr ?? 2.6;
    final starCount = (image.starCount ?? 80).clamp(1, 10000).toDouble();
    final guidingRms = image.guidingRmsTotal ?? 1.4;
    final qualityScore = image.qualityScore ?? 75.0;

    final hfrRatio = referenceHfr != null && referenceHfr > 0
        ? hfr / referenceHfr
        : hfr / 2.6;
    final guidingRatio = referenceGuidingRms != null && referenceGuidingRms > 0
        ? guidingRms / referenceGuidingRms
        : guidingRms / 1.4;
    final starPenalty = 1.0 - (starCount.clamp(20.0, 160.0) - 20.0) / 140.0;
    final qualityPenalty = 1.0 - (qualityScore.clamp(0.0, 100.0) / 100.0);

    final logit =
        -2.9 +
        (hfrRatio - 1.0) * 2.2 +
        (guidingRatio - 1.0) * 1.6 +
        starPenalty * 1.8 +
        qualityPenalty * 2.4;
    return 1.0 / (1.0 + math.exp(-logit));
  }
}

// Image Grading: structured runtime decisions surfaced from the
// Rust sequencer's per-frame grading. The advisory `FrameQualityAssessment`
// above remains for post-capture review; these structures carry the
// real-time accept/reject signal that the Run Dashboard quality panel
// listens for.

/// Outcome of a runtime image-grading decision.
enum FrameGradeDecision {
  /// Frame passed all configured thresholds.
  accepted,

  /// Frame failed at least one threshold and was routed to the reject folder.
  rejected,
}

/// Real-time grading event payload emitted by the sequencer after each
/// frame is graded.
///
/// Built from the typed `SequencerEvent_FrameAccepted` /
/// `SequencerEvent_FrameRejected` payloads via [FrameGradeEvent.fromTypedData],
/// never by parsing `InstructionProgress.detail`, so HFR, eccentricity, star
/// count and consecutive-rejects survive the boundary.
class FrameGradeEvent {
  /// 1-based frame index within the current TakeExposure burst.
  final int frame;
  final int total;
  final FrameGradeDecision decision;

  /// Reject reason text from the Rust side. Empty for accepted frames.
  final String reason;

  /// Path the FITS landed at (accepted = save_path, rejected = Reject/).
  ///
  /// The bridge now ships the save path on accepted
  /// frames too (it always did for rejected frames). `null` only for
  /// legacy emit sites that didn't thread the path through.
  final String? path;

  /// HFR (pixels) when the grader computed star metrics; `null` when star
  /// detection failed or wasn't run. Plumbed end-to-end.
  final double? hfr;

  /// Median eccentricity (0.0 = perfectly round). `null` when not computed.
  final double? eccentricity;

  /// Number of detected stars. `null` when detection didn't run.
  final int? starCount;

  /// Cumulative accepted-frames counter for the run.
  final int acceptedTotal;

  /// Cumulative rejected-frames counter for the run.
  final int rejectedTotal;

  /// Running consecutive-rejects count. 0 after every accepted frame.
  final int consecutiveRejects;

  /// Capture timestamp.
  final DateTime timestamp;

  const FrameGradeEvent({
    required this.frame,
    required this.total,
    required this.decision,
    required this.reason,
    this.path,
    this.hfr,
    this.eccentricity,
    this.starCount,
    required this.acceptedTotal,
    required this.rejectedTotal,
    required this.consecutiveRejects,
    required this.timestamp,
  });

  bool get isReject => decision == FrameGradeDecision.rejected;

  /// Build a [FrameGradeEvent] from a typed `FrameAccepted` /
  /// `FrameRejected` event's `data` map (`SkotiqEvent.eventType` +
  /// `data`). Returns `null` when the event type isn't one of the typed
  /// grade variants.
  static FrameGradeEvent? fromTypedData(
    String eventType,
    Map<String, dynamic> data,
  ) {
    final now = DateTime.now();
    switch (eventType) {
      case 'FrameAccepted':
        return FrameGradeEvent(
          frame: data['frame'] as int,
          total: data['total'] as int,
          decision: FrameGradeDecision.accepted,
          reason: '',
          // Surface the on-disk save_path for accepted
          // frames the same way `reject_path` already worked for
          // rejected frames. Empty or missing means null.
          path: () {
            final raw = data['save_path'] as String?;
            return (raw == null || raw.isEmpty) ? null : raw;
          }(),
          hfr: (data['hfr'] as num?)?.toDouble(),
          eccentricity: (data['eccentricity'] as num?)?.toDouble(),
          starCount: data['star_count'] as int?,
          acceptedTotal: data['accepted_total'] as int,
          rejectedTotal: data['rejected_total'] as int,
          consecutiveRejects: 0,
          timestamp: now,
        );
      case 'FrameRejected':
        return FrameGradeEvent(
          frame: data['frame'] as int,
          total: data['total'] as int,
          decision: FrameGradeDecision.rejected,
          reason: data['reason'] as String? ?? '',
          path: data['reject_path'] as String?,
          hfr: (data['hfr'] as num?)?.toDouble(),
          eccentricity: (data['eccentricity'] as num?)?.toDouble(),
          starCount: data['star_count'] as int?,
          acceptedTotal: data['accepted_total'] as int,
          rejectedTotal: data['rejected_total'] as int,
          consecutiveRejects: data['consecutive_rejects'] as int,
          timestamp: now,
        );
      default:
        return null;
    }
  }
}

/// Run-wide summary of grading decisions, suitable for the dashboard
/// quality panel.
class FrameGradeRunSummary {
  final int accepted;
  final int rejected;

  /// Most-recent N decisions (chronological order, oldest first). The
  /// dashboard renders this as a scrollable list.
  final List<FrameGradeEvent> recent;

  /// HFR samples from ALL graded frames in chronological order; used for
  /// the HFR sparkline on the dashboard. Rejected frames are included —
  /// a focus-drift episode that causes rejections must remain visible in
  /// the trend, not silently vanish from it.
  final List<double> hfrSparkline;

  /// Parallel to [hfrSparkline]: true when the sample came from an
  /// accepted frame, false for a rejected one (rendered distinctly).
  final List<bool> hfrSparklineAccepted;

  const FrameGradeRunSummary({
    required this.accepted,
    required this.rejected,
    required this.recent,
    required this.hfrSparkline,
    this.hfrSparklineAccepted = const [],
  });

  static const empty = FrameGradeRunSummary(
    accepted: 0,
    rejected: 0,
    recent: [],
    hfrSparkline: [],
    hfrSparklineAccepted: [],
  );

  int get total => accepted + rejected;
  double get rejectRate => total == 0 ? 0.0 : rejected / total;
}
