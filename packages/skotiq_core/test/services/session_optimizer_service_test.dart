import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:skotiq_core/skotiq_core.dart';
import 'package:skotiq_core/src/database/database.dart'
    show ImagingSession, Target;
import 'package:skotiq_planetarium/skotiq_planetarium.dart';

class _MockLoggingService extends Mock implements LoggingService {}

/// Build a minimal [SessionReport] fixture so the analyze() tests can
/// hit each insight branch without depending on the live DB stack.
SessionReport _fakeReport({
  Duration wallClock = const Duration(hours: 4),
  Duration integration = const Duration(hours: 3),
  int autofocusRuns = 0,
  int framesAttempted = 100,
  int framesAccepted = 95,
  double? guideRmsTotal,
  List<SessionTargetReport>? targets,
}) {
  final targetsToUse =
      targets ??
      const [
        SessionTargetReport(
          targetId: 1,
          targetName: 'M31',
          filters: [
            SessionFilterReport(
              filter: 'L',
              framesAttempted: 100,
              framesAccepted: 95,
              framesRejected: 5,
              totalIntegrationSecs: 11400,
              meanHfr: 2.4,
              meanFwhm: 5.6,
              meanStarCount: 480,
              meanSnr: 21.5,
              meanGuidingRmsTotal: 0.62,
              meanSensorTemp: -10,
              rejectionReasons: {},
            ),
          ],
        ),
      ];
  // Override per-target frame counts so the test's framesAttempted /
  // framesAccepted arguments propagate consistently to the report.
  final effective = targetsToUse
      .map(
        (t) => SessionTargetReport(
          targetId: t.targetId,
          targetName: t.targetName,
          filters: t.filters
              .map(
                (f) => SessionFilterReport(
                  filter: f.filter,
                  framesAttempted: framesAttempted,
                  framesAccepted: framesAccepted,
                  framesRejected: framesAttempted - framesAccepted,
                  totalIntegrationSecs: f.totalIntegrationSecs,
                  meanHfr: f.meanHfr,
                  meanFwhm: f.meanFwhm,
                  meanStarCount: f.meanStarCount,
                  meanSnr: f.meanSnr,
                  meanGuidingRmsTotal: f.meanGuidingRmsTotal,
                  meanSensorTemp: f.meanSensorTemp,
                  rejectionReasons: f.rejectionReasons,
                ),
              )
              .toList(),
        ),
      )
      .toList();
  return SessionReport(
    sessionId: 1,
    sessionName: 'Test session',
    status: 'completed',
    startTime: DateTime(2026, 1, 1, 22),
    endTime: DateTime(2026, 1, 1, 22).add(wallClock),
    wallClockDuration: wallClock,
    totalIntegration: integration,
    effectiveImagingFraction: wallClock.inSeconds > 0
        ? integration.inSeconds / wallClock.inSeconds
        : 0,
    downtime: wallClock - integration,
    targets: effective,
    guideStats: SessionGuideStats(
      meanRmsRaArcsec: guideRmsTotal,
      meanRmsDecArcsec: guideRmsTotal,
      meanRmsTotalArcsec: guideRmsTotal,
      maxRmsRaArcsec: guideRmsTotal,
      maxRmsDecArcsec: guideRmsTotal,
      maxRmsTotalArcsec: guideRmsTotal,
      percentUnguidedFrames: 0.0,
    ),
    mountStats: SessionMountStats(
      autofocusRuns: autofocusRuns,
      meridianFlips: 0,
      ditherCount: 0,
      triggerFires: 0,
    ),
    avgTemperatureC: null,
    avgHumidityPercent: null,
    avgSeeingArcsec: null,
    notes: null,
    errorMessages: const [],
    warningMessages: const [],
    generatedAt: DateTime(2026, 1, 2),
  );
}

void main() {
  group('SessionOptimizerService', () {
    late SessionOptimizerService service;

    setUp(() {
      service = SessionOptimizerService(
        suggestionService: TargetSuggestionService(
          loggingService: _MockLoggingService(),
        ),
      );
    });

    Target target({
      required int id,
      required String name,
      required double ra,
      required double dec,
      String? objectType,
      double? magnitude,
      int totalPlannedSubs = 0,
      double totalIntegrationSecs = 0,
    }) {
      return Target(
        id: id,
        name: name,
        ra: ra,
        dec: dec,
        objectType: objectType,
        magnitude: magnitude,
        minAltitude: 20,
        totalPlannedSubs: totalPlannedSubs,
        totalIntegrationSecs: totalIntegrationSecs,
        priority: 1,
        capturedSubs: 0,
        goalIntegrationSecs: 0,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        isFavorite: false,
      );
    }

    ImagingSession session({
      required int id,
      required int targetId,
      required double totalIntegrationSecs,
    }) {
      return ImagingSession(
        id: id,
        targetId: targetId,
        startTime: DateTime(2026, 1, 1, 20),
        totalExposures: 10,
        successfulExposures: 10,
        failedExposures: 0,
        totalIntegrationSecs: totalIntegrationSecs,
        autofocusCount: 1,
        status: 'completed',
      );
    }

    test('produces a primary recommendation and alternates', () async {
      final plan = await service.optimizeTonight(
        config: const TargetSuggestionConfig(minAltitude: 0, minScore: 0),
        latitude: 40,
        longitude: -75,
        targets: [
          target(id: 1, name: 'Vega', ra: 18.6, dec: 38.8, objectType: 'Star'),
          target(id: 2, name: 'Deneb', ra: 20.7, dec: 45.3, objectType: 'Star'),
          target(
            id: 3,
            name: 'Andromeda',
            ra: 0.7,
            dec: 41.3,
            objectType: 'Galaxy',
          ),
        ],
        sessions: const [],
        observationTime: DateTime(2026, 8, 1, 22),
      );

      expect(plan.hasRecommendation, isTrue);
      expect(plan.primaryTarget, isNotNull);
      expect(plan.alternates.length, lessThanOrEqualTo(3));
      expect(plan.recommendedExposureSeconds, greaterThan(0));
      expect(plan.rationale, isNotEmpty);
    });

    test('returns actionable fallback when no targets fit', () async {
      final plan = await service.optimizeTonight(
        config: const TargetSuggestionConfig(minAltitude: 80, minScore: 95),
        latitude: 40,
        longitude: -75,
        targets: [target(id: 1, name: 'Low South', ra: 12, dec: -70)],
        sessions: const [],
        observationTime: DateTime(2026, 3, 1, 22),
      );

      expect(plan.hasRecommendation, isFalse);
      expect(plan.rationale.single, contains('No viable targets'));
      expect(plan.riskFactors.single, contains('constraints'));
    });

    test('flags nearly complete targets as a risk factor', () async {
      final plan = await service.optimizeTonight(
        config: const TargetSuggestionConfig(minAltitude: 0, minScore: 0),
        latitude: 40,
        longitude: -75,
        targets: [
          target(
            id: 1,
            name: 'Almost Done',
            ra: 18.6,
            dec: 38.8,
            totalPlannedSubs: 100,
          ),
        ],
        sessions: [session(id: 1, targetId: 1, totalIntegrationSecs: 27000)],
        observationTime: DateTime(2026, 8, 1, 22),
      );

      expect(
        plan.riskFactors.any((factor) => factor.contains('nearly complete')),
        isTrue,
      );
    });

    test(
      'uses Smart Night exposure math when exposure context is available',
      () {
        final plan = service.buildPlanFromSuggestions(
          [
            const TargetSuggestion(
              targetId: 42,
              targetName: 'North America Nebula',
              raHours: 20.98,
              decDegrees: 44.33,
              totalScore: 91,
              visibility: TargetVisibilityInfo(
                currentAltitude: 62,
                currentAzimuth: 120,
                airmass: 1.1,
                moonDistance: 110,
                peakAltitude: 75,
                hoursAboveMinAlt: 5.5,
              ),
              objectType: 'Emission Nebula',
              magnitude: 4.0,
            ),
          ],
          generatedAt: DateTime(2026, 8, 1, 22),
          exposureContext: const SmartNightExposureContext(
            camera: CameraExposureSpec(
              readNoiseE: 1.5,
              fullWellE: 18000,
              qePeak: 0.8,
            ),
            bortleClass: 5,
            focalLengthMm: 480,
            apertureMm: 80,
            pixelSizeMicrons: 3.76,
            availableFilterNames: ['Ha'],
          ),
        );

        expect(plan.recommendedExposureSeconds, equals(300));
        expect(plan.recommendedFilterName, equals('Ha'));
        expect(plan.recommendedFilterNames, equals(['Ha']));
        expect(plan.rationale.any((line) => line.contains('Glover')), isTrue);
        expect(
          plan.riskFactors.any((line) => line.contains('lookup table')),
          isFalse,
        );
      },
    );

    // A target with ZERO captured frames was described as a "large unfinished
    // dataset" and an "efficient completion target" in the same rationale
    // block that said "No data collected yet". dataProgress is exactly 0.0
    // only when nothing has been captured, so the claim is now gated on there
    // being something to finish.
    TargetSuggestion untouched({required double dataProgress}) {
      return TargetSuggestion(
        targetId: 7,
        targetName: 'NGC 6015',
        raHours: 15.86,
        decDegrees: 62.3,
        totalScore: 76,
        dataProgress: dataProgress,
        visibility: const TargetVisibilityInfo(
          currentAltitude: 55,
          currentAzimuth: 30,
          airmass: 1.2,
          moonDistance: 102,
          peakAltitude: 62,
          hoursAboveMinAlt: 5,
        ),
        objectType: 'Galaxy',
        magnitude: 11.2,
      );
    }

    test('a target with no frames is not called an unfinished dataset', () {
      final plan = service.buildPlanFromSuggestions([
        untouched(dataProgress: 0.0),
      ], generatedAt: DateTime(2026, 8, 1, 22));

      expect(
        plan.rationale.any((line) => line.contains('unfinished dataset')),
        isFalse,
      );
      expect(
        plan.rationale.any((line) => line.contains('completion target')),
        isFalse,
      );
      expect(
        plan.rationale.any((line) => line.contains('Partially captured')),
        isFalse,
      );
    });

    test('a partially captured target still gets the completion rationale', () {
      final plan = service.buildPlanFromSuggestions([
        untouched(dataProgress: 0.1),
      ], generatedAt: DateTime(2026, 8, 1, 22));

      expect(
        plan.rationale.any((line) => line.contains('Partially captured')),
        isTrue,
      );
    });

    test('a rig with no filters recommends no filter name', () {
      final plan = service.buildPlanFromSuggestions(
        [
          const TargetSuggestion(
            targetId: 31,
            targetName: 'M31',
            raHours: 0.712,
            decDegrees: 41.2,
            totalScore: 84,
            visibility: TargetVisibilityInfo(
              currentAltitude: 60,
              currentAzimuth: 90,
              airmass: 1.15,
              moonDistance: 100,
              peakAltitude: 72,
              hoursAboveMinAlt: 6,
            ),
            objectType: 'Galaxy',
          ),
        ],
        generatedAt: DateTime(2026, 8, 1, 22),
        exposureContext: const SmartNightExposureContext(
          camera: CameraExposureSpec(
            readNoiseE: 1.5,
            fullWellE: 51000,
            qePeak: 0.91,
          ),
          bortleClass: 5,
          focalLengthMm: 250,
          apertureMm: 51,
          pixelSizeMicrons: 3.76,
        ),
      );

      expect(plan.recommendedExposureSeconds, greaterThan(0));
      expect(plan.recommendedFilterName, isNull);
      expect(plan.recommendedFilterNames, isEmpty);
    });

    test('planetary nebula prefers luminance over narrowband for exposure', () {
      const context = SmartNightExposureContext(
        camera: CameraExposureSpec(
          readNoiseE: 1.5,
          fullWellE: 18000,
          qePeak: 0.8,
        ),
        bortleClass: 5,
        focalLengthMm: 480,
        apertureMm: 80,
        pixelSizeMicrons: 3.76,
        availableFilterNames: ['L', 'R', 'G', 'B', 'Ha', 'OIII', 'SII'],
      );
      final plan = service.buildPlanFromSuggestions(
        [
          const TargetSuggestion(
            targetId: 57,
            targetName: 'M57',
            raHours: 18.89,
            decDegrees: 33.03,
            totalScore: 88,
            visibility: TargetVisibilityInfo(
              currentAltitude: 62,
              currentAzimuth: 120,
              airmass: 1.1,
              moonDistance: 110,
              peakAltitude: 75,
              hoursAboveMinAlt: 5.5,
            ),
            objectType: 'Planetary Nebula',
            magnitude: 8.8,
          ),
        ],
        generatedAt: DateTime(2026, 8, 1, 22),
        exposureContext: context,
      );

      expect(plan.recommendedFilterName, equals('L'));
      expect(plan.recommendedFilterNames, equals(['L', 'R', 'G', 'B']));
      expect(
        context
            .selectFilterForTarget(
              const TargetSuggestion(
                targetId: 57,
                targetName: 'M57',
                raHours: 18.89,
                decDegrees: 33.03,
                totalScore: 88,
                visibility: TargetVisibilityInfo(
                  currentAltitude: 62,
                  currentAzimuth: 120,
                  airmass: 1.1,
                  moonDistance: 110,
                  peakAltitude: 75,
                  hoursAboveMinAlt: 5.5,
                ),
                objectType: 'Planetary Nebula',
              ),
            )
            .name,
        equals('L'),
      );
    });

    test(
      'generic nebula label prefers luminance over narrowband for exposure',
      () {
        const context = SmartNightExposureContext(
          camera: CameraExposureSpec(
            readNoiseE: 1.5,
            fullWellE: 18000,
            qePeak: 0.8,
          ),
          bortleClass: 5,
          focalLengthMm: 480,
          apertureMm: 80,
          pixelSizeMicrons: 3.76,
          availableFilterNames: ['L', 'Ha', 'OIII'],
        );
        final filter = context.selectFilterForTarget(
          const TargetSuggestion(
            targetId: 2244,
            targetName: 'NGC 2244',
            raHours: 6.32,
            decDegrees: 4.9,
            totalScore: 80,
            visibility: TargetVisibilityInfo(
              currentAltitude: 55,
              currentAzimuth: 180,
              airmass: 1.2,
              moonDistance: 90,
              peakAltitude: 70,
              hoursAboveMinAlt: 4.0,
            ),
            objectType: 'Nebula',
          ),
        );

        expect(filter.name, equals('L'));
      },
    );

    test(
      'falls back to Smart Night exposure math when context is unavailable',
      () {
        final plan = service.buildPlanFromSuggestions([
          const TargetSuggestion(
            targetId: 43,
            targetName: 'Fallback Nebula',
            raHours: 20.98,
            decDegrees: 44.33,
            totalScore: 88,
            visibility: TargetVisibilityInfo(
              currentAltitude: 62,
              currentAzimuth: 120,
              airmass: 1.1,
              moonDistance: 110,
              peakAltitude: 75,
              hoursAboveMinAlt: 5.5,
            ),
            objectType: 'Emission Nebula',
            magnitude: 4.0,
          ),
        ], generatedAt: DateTime(2026, 8, 1, 22));

        expect(plan.recommendedExposureSeconds, greaterThan(0));
        expect(plan.recommendedFilterName, equals('L'));
        expect(plan.rationale.any((line) => line.contains('Glover')), isTrue);
        expect(
          plan.riskFactors.any((line) => line.contains('planning estimate')),
          isTrue,
        );
      },
    );

    test(
      'builds mosaic exposure defaults from the shared Smart Night context',
      () {
        const context = SmartNightExposureContext(
          camera: CameraExposureSpec(
            readNoiseE: 1.5,
            fullWellE: 18000,
            qePeak: 0.8,
          ),
          bortleClass: 5,
          focalLengthMm: 480,
          apertureMm: 80,
          pixelSizeMicrons: 3.76,
          availableFilterNames: ['R', 'L', 'Ha'],
        );
        final exposure = smartNightMosaicExposureSettings(context);

        expect(exposure.filterName, equals('L'));
        expect(
          exposure.exposureSeconds,
          equals(context.recommendForFilter('L').seconds),
        );
        expect(exposure.exposuresPerPanel, equals(10));
        expect(exposure.binning, equals(1));
      },
    );

    // Post-session analyze() insights

    test('analyze surfaces altitudeWindow insight from trace data', () {
      final report = _fakeReport(
        wallClock: const Duration(hours: 6),
        integration: const Duration(hours: 5),
      );
      final insights = service.analyze(
        report: report,
        altitudeTraces: const [
          SessionTargetAltitudeTrace(
            targetId: 1,
            targetName: 'M31',
            secondsBelowMinAltitude: 5400, // 90 minutes
            minRecommendedAltitudeDeg: 40,
            minObservedAltitudeDeg: 30,
          ),
        ],
      );
      final altitudeInsight = insights.where(
        (i) => i.kind == SessionInsightKind.altitudeWindow,
      );
      expect(altitudeInsight, isNotEmpty);
      final i = altitudeInsight.first;
      expect(i.applyHint, isNotNull);
      expect(i.applyHint!['altitudeAboveDeg'], isA<double>());
      // Suggested value should be observed-min + margin (30 + 5 = 35).
      expect(i.applyHint!['altitudeAboveDeg'], equals(35.0));
      // The hint carries the target name so the UI resolves the right target
      // when applying the suggestion on a multi-target sequence.
      expect(i.applyHint!['targetName'], equals('M31'));
      expect(i.title, contains('M31'));
      expect(i.title, contains('40°'));
    });

    test('analyze surfaces autofocusFrequency when AF runs are excessive', () {
      final report = _fakeReport(
        wallClock: const Duration(hours: 4),
        autofocusRuns: 25, // 6.25/hour, above 4/hour threshold
      );
      final insights = service.analyze(report: report);
      final afInsight = insights.where(
        (i) => i.kind == SessionInsightKind.autofocusFrequency,
      );
      expect(afInsight, isNotEmpty);
      expect(afInsight.first.applyHint, isNotNull);
      expect(
        afInsight.first.applyHint!.containsKey('autofocusInterval'),
        isTrue,
      );
    });

    test('analyze surfaces rejectionRate when reject fraction is high', () {
      final report = _fakeReport(
        framesAttempted: 100,
        framesAccepted: 70, // 30% reject rate
      );
      final insights = service.analyze(report: report);
      expect(
        insights.where((i) => i.kind == SessionInsightKind.rejectionRate),
        isNotEmpty,
      );
    });

    test('analyze surfaces guidingDegraded when RMS exceeds threshold', () {
      final report = _fakeReport(guideRmsTotal: 2.5);
      final insights = service.analyze(report: report);
      expect(
        insights.where((i) => i.kind == SessionInsightKind.guidingDegraded),
        isNotEmpty,
      );
    });

    test('analyze suppresses dismissed insight ids', () {
      final report = _fakeReport(guideRmsTotal: 2.5);
      final insights = service.analyze(
        report: report,
        thresholds: const SessionInsightThresholds(
          dismissedIds: {'guiding_degraded'},
        ),
      );
      expect(
        insights.where((i) => i.kind == SessionInsightKind.guidingDegraded),
        isEmpty,
      );
    });

    test('analyze sorts insights by confidence descending', () {
      // Build a session that triggers multiple insights with different
      // confidence levels.
      final report = _fakeReport(
        wallClock: const Duration(hours: 6),
        integration: const Duration(hours: 2), // 33% efficiency
        autofocusRuns: 30, // 5/hour
        framesAttempted: 100,
        framesAccepted: 65, // 35% rejected
        guideRmsTotal: 2.5,
      );
      final insights = service.analyze(report: report);
      expect(insights.length, greaterThan(1));
      for (var i = 1; i < insights.length; i++) {
        expect(
          insights[i - 1].confidence,
          greaterThanOrEqualTo(insights[i].confidence),
        );
      }
    });

    test('analyze returns empty list when report is healthy', () {
      final report = _fakeReport(
        wallClock: const Duration(hours: 4),
        integration: const Duration(hours: 3),
        autofocusRuns: 1,
        framesAttempted: 100,
        framesAccepted: 98,
        guideRmsTotal: 0.6,
      );
      final insights = service.analyze(report: report);
      expect(insights, isEmpty);
    });
  });
}
