import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart'
    show
        FrameGradingMode,
        FrameQualityAssessment,
        FrameQualityAssessmentService,
        FrameQualityDisposition,
        FrameQualityLevel;
import 'package:skotiq_core/src/database/database.dart' show CapturedImage;

CapturedImage _image({
  required int id,
  double? qualityScore,
  double? hfr,
  int? starCount,
  double? guidingRmsTotal,
}) {
  final now = DateTime(2026, 1, 1, 0, 0);
  return CapturedImage(
    id: id,
    filePath: '/tmp/$id.fits',
    fileName: '$id.fits',
    fileFormat: 'fits',
    frameType: 'light',
    exposureDuration: 300,
    binX: 1,
    binY: 1,
    qualityScore: qualityScore,
    hfr: hfr,
    starCount: starCount,
    guidingRmsTotal: guidingRmsTotal,
    isPlateSolved: false,
    capturedAt: now,
    createdAt: now,
    isAccepted: true,
  );
}

void main() {
  group('FrameQualityAssessmentService', () {
    const service = FrameQualityAssessmentService();

    /// A frame can be demoted by the composite score alone: `advisoryScore`
    /// starts at the frame's own `qualityScore`, so one that trips no individual
    /// threshold but scores in the 60s still lands in `needsReview`. Arriving
    /// with an EMPTY reason list, the gallery says "Needs Review" and gives the
    /// operator nothing to act on — real captures score 64-66 at a healthy
    /// HFR 2.5px / 200 stars.
    test('needsReview by score alone still carries a reason', () {
      final result = service.assessFrame(
        _image(id: 1, qualityScore: 64.4, hfr: 2.5, starCount: 200),
      );

      expect(result.level, FrameQualityLevel.needsReview);
      expect(result.reasons, isNotEmpty);
      expect(result.reasons.single, contains('64/100'));
    });

    test('a good frame gains no synthetic reason', () {
      final result = service.assessFrame(
        _image(id: 2, qualityScore: 88, hfr: 2.0, starCount: 400),
      );

      expect(result.level, FrameQualityLevel.good);
      expect(result.reasons, isEmpty);
    });

    test('classifies a clean frame as good', () {
      final result = service.assessFrame(
        _image(
          id: 1,
          qualityScore: 88,
          hfr: 2.2,
          starCount: 120,
          guidingRmsTotal: 1.1,
        ),
      );

      expect(result.level, FrameQualityLevel.good);
      expect(result.needsReview, isFalse);
      expect(result.reasons, isEmpty);
    });

    test('classifies strongly degraded frame as poor with reasons', () {
      final result = service.assessFrame(
        _image(
          id: 2,
          qualityScore: 35,
          hfr: 5.1,
          starCount: 12,
          guidingRmsTotal: 3.4,
        ),
      );

      expect(result.level, FrameQualityLevel.poor);
      expect(result.needsReview, isTrue);
      expect(result.reasons, isNotEmpty);
      // Default mode is advisory: even strongly degraded frames are
      // surfaced as review-needed, not auto-rejected.
      expect(result.disposition, FrameQualityDisposition.review);
      expect(result.autoRejectCandidate, isFalse);
      expect(
        result.reasons.any((reason) => reason.contains('Very soft stars')),
        isTrue,
      );
    });

    test('elevates heuristic score when multiple quality features degrade', () {
      final result = service.assessFrame(
        _image(
          id: 4,
          qualityScore: 48,
          hfr: 4.2,
          starCount: 18,
          guidingRmsTotal: 2.7,
        ),
        referenceHfr: 2.1,
        referenceGuidingRms: 1.0,
      );

      // Score still reaches the legacy "auto" trigger threshold of 0.88,
      // but under the advisory default the disposition must remain at
      // `review` rather than `autoReject` (audit ).
      expect(result.heuristicScore, greaterThan(0.88));
      expect(result.autoRejectCandidate, isFalse);
      expect(result.disposition, FrameQualityDisposition.review);
    });

    test('uses session medians to flag HFR outliers', () {
      final frames = [
        _image(
          id: 1,
          qualityScore: 85,
          hfr: 2.1,
          starCount: 100,
          guidingRmsTotal: 1.0,
        ),
        _image(
          id: 2,
          qualityScore: 84,
          hfr: 2.2,
          starCount: 98,
          guidingRmsTotal: 1.1,
        ),
        _image(
          id: 3,
          qualityScore: 80,
          hfr: 4.8,
          starCount: 70,
          guidingRmsTotal: 1.1,
        ),
      ];

      final batch = service.assessBatch(frames);
      final outlier = batch[3]!;

      expect(outlier.level, isNot(FrameQualityLevel.good));
      expect(
        outlier.reasons.any((reason) => reason.contains('session median')),
        isTrue,
      );
    });

    test('builds summary counts from assessments', () {
      final assessments = {
        1: const FrameQualityAssessment(
          level: FrameQualityLevel.good,
          advisoryScore: 90,
          reasons: [],
        ),
        2: const FrameQualityAssessment(
          level: FrameQualityLevel.needsReview,
          advisoryScore: 62,
          reasons: ['Low star count'],
        ),
        3: const FrameQualityAssessment(
          level: FrameQualityLevel.poor,
          advisoryScore: 30,
          reasons: ['Very soft stars'],
        ),
      };

      final summary = service.summarize(assessments);

      expect(summary.total, 3);
      expect(summary.good, 1);
      expect(summary.needsReview, 1);
      expect(summary.poor, 1);
    });
  });

  group('FrameQualityAssessmentService.computeHeuristicScore', () {
    const service = FrameQualityAssessmentService();

    test('clean frame produces low heuristic score', () {
      final score = service.computeHeuristicScore(
        _image(
          id: 1,
          qualityScore: 90,
          hfr: 1.8,
          starCount: 200,
          guidingRmsTotal: 0.7,
        ),
      );
      expect(score, lessThan(0.20));
    });

    test(
      'degraded frame produces high heuristic score above legacy threshold',
      () {
        final score = service.computeHeuristicScore(
          _image(
            id: 2,
            qualityScore: 30,
            hfr: 5.0,
            starCount: 15,
            guidingRmsTotal: 3.5,
          ),
          referenceHfr: 2.0,
          referenceGuidingRms: 1.0,
        );
        expect(score, greaterThan(0.88));
      },
    );

    test('matches known-input expected value within tolerance', () {
      // Direct computation: with hfr=2.6 / starCount=80 / guidingRms=1.4 /
      // qualityScore=75 and no references, every ratio/penalty term is
      // tuned so the formula sits at ~0.18 (just shy of the "needs
      // review" trigger). This pins the formula so a coefficient drift
      // is caught immediately.
      final score = service.computeHeuristicScore(
        _image(
          id: 3,
          qualityScore: 75,
          hfr: 2.6,
          starCount: 80,
          guidingRmsTotal: 1.4,
        ),
      );
      // hfrRatio=1, guidingRatio=1, starPenalty=(1 - 60/140)=0.5714,
      // qualityPenalty=0.25 -> logit = -2.9 + 0 + 0 + 1.0286 + 0.6
      //                              = -1.2714 -> sigmoid ~= 0.219
      expect(score, closeTo(0.219, 0.005));
    });
  });

  group('FrameGradingMode', () {
    test('advisory mode never sets autoReject even with extreme score', () {
      const service = FrameQualityAssessmentService(
        gradingMode: FrameGradingMode.advisory,
      );
      final result = service.assessFrame(
        _image(
          id: 10,
          qualityScore: 20,
          hfr: 6.0,
          starCount: 5,
          guidingRmsTotal: 4.0,
        ),
        referenceHfr: 2.0,
        referenceGuidingRms: 1.0,
      );

      expect(result.heuristicScore, greaterThan(0.88));
      expect(result.disposition, isNot(FrameQualityDisposition.autoReject));
      expect(result.autoRejectCandidate, isFalse);
      expect(
        result.reasons.any(
          (r) => r.startsWith('Quality heuristic') && r.contains('advisory'),
        ),
        isTrue,
      );
    });

    test('auto mode preserves legacy auto-reject behaviour', () {
      const service = FrameQualityAssessmentService(
        gradingMode: FrameGradingMode.auto,
      );
      final result = service.assessFrame(
        _image(
          id: 11,
          qualityScore: 20,
          hfr: 6.0,
          starCount: 5,
          guidingRmsTotal: 4.0,
        ),
        referenceHfr: 2.0,
        referenceGuidingRms: 1.0,
      );

      expect(result.heuristicScore, greaterThan(0.88));
      expect(result.disposition, FrameQualityDisposition.autoReject);
      expect(result.autoRejectCandidate, isTrue);
      expect(result.reasons.any((r) => r.contains('auto-rejected')), isTrue);
    });

    test(
      'off mode keeps clean frames as keep and degraded frames as review',
      () {
        const service = FrameQualityAssessmentService(
          gradingMode: FrameGradingMode.off,
        );

        final clean = service.assessFrame(
          _image(
            id: 12,
            qualityScore: 88,
            hfr: 2.0,
            starCount: 150,
            guidingRmsTotal: 0.8,
          ),
        );
        expect(clean.disposition, FrameQualityDisposition.keep);
        // In off mode no advisory text about the heuristic is appended.
        expect(
          clean.reasons.any((r) => r.startsWith('Quality heuristic')),
          isFalse,
        );

        final bad = service.assessFrame(
          _image(
            id: 13,
            qualityScore: 20,
            hfr: 6.0,
            starCount: 5,
            guidingRmsTotal: 4.0,
          ),
        );
        expect(bad.disposition, FrameQualityDisposition.review);
        expect(bad.autoRejectCandidate, isFalse);
      },
    );
  });

  group('Backward compatibility', () {
    test('default constructor still works without arguments', () {
      // The renamed field is the only behaviour change exposed in the
      // public API. `const FrameQualityAssessmentService()` is widely
      // used in call sites (analytics thumbnail strip) — make sure it
      // still resolves to the advisory default.
      const service = FrameQualityAssessmentService();
      expect(service.gradingMode, FrameGradingMode.advisory);
    });

    test('FrameQualityAssessment heuristicScore default is 0.5', () {
      const assessment = FrameQualityAssessment(
        level: FrameQualityLevel.good,
        advisoryScore: 80,
        reasons: [],
      );
      expect(assessment.heuristicScore, 0.5);
      expect(assessment.disposition, FrameQualityDisposition.keep);
    });
  });
}
