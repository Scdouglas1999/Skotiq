import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/skotiq_core.dart' hide CapturedImage;
import 'package:skotiq_core/src/database/database.dart' show CapturedImage;
import 'package:skotiq_core/src/services/science/narrator/narrator_context.dart';
import 'package:skotiq_core/src/services/science/narrator/narrator_service.dart';

/// Service-level wiring test: builds a [NarratorService] over a
/// [ProviderContainer] whose pull-sources are overridden with synthetic data,
/// and asserts that [NarratorService.buildContextForTest] surfaces each pulled
/// input into the [NarratorContext], so the detectors receive real data rather
/// than a hardcoded-empty `lightCurve`, `diagnostics` or `filterIntegration`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const sessionId = 1;
  final t0 = DateTime.utc(2026, 6, 11, 22);

  late SkotiqDatabase db;

  setUp(() async {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    await db
        .into(db.imagingSessions)
        .insert(
          ImagingSessionsCompanion.insert(
            id: const Value(sessionId),
            startTime: t0,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  CapturedImage image({
    required int id,
    required double hfr,
    required int starCount,
    bool accepted = true,
    String? rejectionReason,
    bool solved = true,
    double focuserTemp = 5.0,
    String filter = 'L',
    double exposure = 300,
    double? background,
  }) {
    return CapturedImage(
      id: id,
      filePath: '/tmp/$id.fits',
      fileName: '$id.fits',
      fileFormat: 'fits',
      sessionId: sessionId,
      frameType: 'light',
      exposureDuration: exposure,
      binX: 1,
      binY: 1,
      filter: filter,
      hfr: hfr,
      starCount: starCount,
      background: background,
      focuserTemp: focuserTemp,
      isPlateSolved: solved,
      capturedAt: t0.add(Duration(minutes: id)),
      createdAt: t0.add(Duration(minutes: id)),
      isAccepted: accepted,
      rejectionReason: rejectionReason,
    );
  }

  FramePhotometricCalibrationRow calib(int id) {
    return FramePhotometricCalibrationRow(
      bandIsStandard: false,
      id: id,
      isCalibrated: true,
      matchedStarCount: 40,
      calibrationRms: 0.03,
      catalogSource: 'auto',
      solverId: 'test',
      timestamp: t0.add(Duration(minutes: id)),
      zeroPoint: 22.0,
      limitingMag5Sigma: 18.5,
    );
  }

  LightCurvePoint lc(int i) => LightCurvePoint(
    timestamp: t0.add(Duration(minutes: i)),
    flux: 1000,
    differentialMagnitude: 12.0,
    snr: 50,
    uncertainty: 0.01,
  );

  ProviderContainer makeContainer({
    List<CapturedImage> images = const [],
    List<LightCurvePoint> lightCurve = const [],
    List<NarratorFilterIntegration> filterIntegration = const [],
    OpticalTrainDiagnostics? diagnostics,
    List<FramePhotometricCalibrationRow> calibrations = const [],
    double? cloudCover,
    Phd2GuideStats guideStats = const Phd2GuideStats(),
  }) {
    return ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        guideStatsProvider.overrideWith(
          (ref) => _FakeGuideStats(ref, guideStats),
        ),
        cloudCoverPercentageProvider.overrideWith((ref) async => cloudCover),
        sessionImagesStreamProvider.overrideWith((ref, sid) {
          return Stream.value(images);
        }),
        sessionFilterIntegrationProvider.overrideWith((ref, sid) {
          return Stream.value(filterIntegration);
        }),
        sessionLightCurveProvider.overrideWith((ref, args) => lightCurve),
        sessionFrameCalibrationsProvider.overrideWith(
          (ref, sid) => Stream.value(calibrations),
        ),
        opticalTrainDiagnosticsProvider.overrideWith(
          (ref, sid) => diagnostics == null
              ? const AsyncValue.loading()
              : AsyncValue.data(diagnostics),
        ),
      ],
    );
  }

  NarratorService startService(ProviderContainer container) {
    final service = container.read(_testServiceProvider(sessionId));
    service.setClock(() => t0.add(const Duration(hours: 1)));
    return service;
  }

  test('light curve is pulled from sessionLightCurveProvider', () async {
    final container = makeContainer(
      lightCurve: [for (var i = 0; i < 12; i++) lc(i)],
    );
    addTearDown(container.dispose);
    final service = startService(container);
    await service.start();
    await Future<void>.delayed(Duration.zero);

    final ctx = service.buildContextForTest();
    expect(ctx.lightCurve, hasLength(12));
  });

  test(
    'optical-train diagnostics are pulled (no longer hardcoded null)',
    () async {
      final container = makeContainer(
        diagnostics: const OpticalTrainDiagnostics(
          tiltScore: 22.0,
          collimationScore: 5.0,
          dominantTiltDirection: 'NE',
          issues: [],
        ),
      );
      addTearDown(container.dispose);
      final service = startService(container);
      await service.start();
      await Future<void>.delayed(Duration.zero);

      final ctx = service.buildContextForTest();
      expect(ctx.diagnostics, isNotNull);
      expect(ctx.diagnostics!.tiltScore, 22.0);
      expect(ctx.diagnostics!.dominantTiltDirection, 'NE');
    },
  );

  test('filter integration is pulled (no longer hardcoded empty)', () async {
    final container = makeContainer(
      filterIntegration: const [
        NarratorFilterIntegration(filter: 'Ha', seconds: 7200),
      ],
    );
    addTearDown(container.dispose);
    final service = startService(container);
    await service.start();
    await Future<void>.delayed(Duration.zero);

    final ctx = service.buildContextForTest();
    expect(ctx.filterIntegration, hasLength(1));
    expect(ctx.filterIntegration.first.filter, 'Ha');
    expect(ctx.filterIntegration.first.seconds, 7200);
  });

  test('weather state is mapped from cloud cover', () async {
    final container = makeContainer(cloudCover: 80.0);
    addTearDown(container.dispose);
    final service = startService(container);
    await service.start();
    await Future<void>.delayed(Duration.zero);

    final ctx = service.buildContextForTest();
    expect(ctx.weather, isNotNull);
    expect(ctx.weather!.cloudCoverPercent, 80.0);
    expect(ctx.weather!.cloudy, isTrue);
  });

  test('ingested First Light candidates surface into the context (Pillar B '
      'wiring)', () async {
    final container = makeContainer();
    addTearDown(container.dispose);
    final service = startService(container);
    await service.start();
    await Future<void>.delayed(Duration.zero);

    // Before ingest the field is empty (the bug: nothing ever set it).
    expect(service.buildContextForTest().transientCandidates, isEmpty);

    service.ingestTransientCandidates(const [
      TransientCandidate(
        ra: 120.0,
        dec: 25.0,
        tileId: 42,
        tileX: 512,
        tileY: 600,
        residualFlux: 5000,
        deltaMag: null,
        snr: 18.0,
        fwhm: 2.1,
        eccentricity: 0.1,
        positionAngleDeg: 0.0,
        kind: TransientKind.newSource,
        confidence: 0.9,
      ),
    ], capturedImageId: 7);

    final ctx = service.buildContextForTest();
    expect(ctx.transientCandidates, hasLength(1));
    expect(ctx.transientCandidates.single.kind, TransientKind.newSource);

    // Let the engine tick the ingest triggers settle before teardown disposes
    // the container (the ingest fires an async evaluate -> persist).
    await Future<void>.delayed(Duration.zero);
    service.dispose();
  });

  test('guide RMS history is pulled from guideStatsProvider', () async {
    final container = makeContainer(
      guideStats: const Phd2GuideStats(rmsTotal: 0.42),
    );
    addTearDown(container.dispose);
    final service = startService(container);
    await service.start();
    await Future<void>.delayed(Duration.zero);

    final ctx = service.buildContextForTest();
    expect(ctx.guideRmsTotalHistory, isNotEmpty);
    expect(ctx.guideRmsTotal, closeTo(0.42, 1e-9));
  });

  test(
    'per-frame image stats / grade / solve are derived from the image stream',
    () async {
      final container = makeContainer(
        images: [
          image(id: 1, hfr: 2.0, starCount: 800),
          image(id: 2, hfr: 2.1, starCount: 790),
          image(
            id: 3,
            hfr: 3.5,
            starCount: 120,
            accepted: false,
            rejectionReason: 'Auto-grade: HFR 3.50 > 3.20',
            solved: false,
          ),
        ],
      );
      addTearDown(container.dispose);
      final service = startService(container);
      await service.start();
      await Future<void>.delayed(Duration.zero);

      final ctx = service.buildContextForTest();
      expect(ctx.imageStats, hasLength(3));
      expect(ctx.imageStats.first.hfr, 2.0);
      expect(ctx.imageStats.last.starCount, 120);
      expect(ctx.imageStats.last.focuserTempC, 5.0);

      expect(ctx.gradeEvents, hasLength(3));
      expect(ctx.gradeEvents.last.rejected, isTrue);
      expect(ctx.gradeEvents.last.reason, contains('HFR'));

      expect(ctx.solveHistory, [true, true, false]);
    },
  );

  test(
    'filter-aware sky samples are derived from frame background/exposure',
    () async {
      final container = makeContainer(
        images: [
          image(
            id: 1,
            hfr: 2.0,
            starCount: 800,
            background: 600,
            exposure: 300,
          ),
          image(
            id: 2,
            hfr: 2.0,
            starCount: 800,
            background: 300,
            exposure: 300,
          ),
          // No background → no sample.
          image(id: 3, hfr: 2.0, starCount: 800),
        ],
      );
      addTearDown(container.dispose);
      final service = startService(container);
      await service.start();
      await Future<void>.delayed(Duration.zero);

      final ctx = service.buildContextForTest();
      expect(ctx.skySamples, hasLength(2));
      // Background normalized by exposure → ADU/s.
      expect(ctx.skySamples.first.aduPerSecond, closeTo(2.0, 1e-9));
      expect(ctx.skySamples.last.aduPerSecond, closeTo(1.0, 1e-9));
      expect(ctx.skySamples.first.filter, 'L');
    },
  );

  test('calibrations are pulled (calibratedFrameCount populated)', () async {
    final container = makeContainer(
      calibrations: [calib(1), calib(2), calib(3)],
    );
    addTearDown(container.dispose);
    final service = startService(container);
    await service.start();
    await Future<void>.delayed(Duration.zero);

    final ctx = service.buildContextForTest();
    expect(ctx.calibrations, hasLength(3));
    expect(ctx.calibratedFrameCount, 3);
  });
}

/// Test-only provider that constructs the service with a real [Ref] from the
/// container. Overridden in each test to bind the session id.
final _testServiceProvider = Provider.family<NarratorService, int>(
  (ref, sessionId) => NarratorService(ref, sessionId: sessionId),
);

/// Seeds [GuideStatsNotifier] with a fixed reading so the service's pulled
/// guide-RMS subscription has data on its first (fireImmediately) read.
class _FakeGuideStats extends GuideStatsNotifier {
  _FakeGuideStats(super.ref, Phd2GuideStats seed) {
    state = seed;
  }
}
