import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/services/darkroom_pass/pass_log.dart';
import 'package:skotiq_core/src/database/daos/dark_library_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/color_calibration_result.dart';
import 'package:skotiq_core/src/models/imaging/integrated_master.dart';
import 'package:skotiq_core/src/models/imaging/integration_curve.dart';
import 'package:skotiq_core/src/models/imaging/integration_settings.dart';
import 'package:skotiq_core/src/models/imaging/mosaic_stitch_result.dart';
import 'package:skotiq_core/src/models/imaging/star_photometry.dart';
import 'package:skotiq_core/src/services/calibration_library_service.dart';
import 'package:skotiq_core/src/services/dark_library_service.dart';
import 'package:skotiq_core/src/services/post_session_integration_service.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';
import 'package:skotiq_core/src/services/wcs_overlay.dart';

/// Records the args of every call and returns scriptable results, so the
/// orchestration services run end-to-end without native code.
class FakePostSessionSeam implements PostSessionSeam {
  final List<Map<String, dynamic>> integrateCalls = [];
  final List<Map<String, dynamic>> accumulateCalls = [];
  final List<Map<String, dynamic>> flatCalls = [];

  /// Optional override for the integrate result builder; defaults to echoing
  /// one accepted record per supplied light path.
  IntegrateSessionResult Function(Map<String, dynamic> args)? integrateBuilder;

  /// Scripted accumulate results keyed by op, popped in order.
  final Map<String, List<MasterAccumulateResult>> scriptedAccumulate = {};

  @override
  Future<IntegrateSessionResult> integrateSession(
    Map<String, dynamic> args,
  ) async {
    integrateCalls.add(args);
    if (integrateBuilder != null) return integrateBuilder!(args);
    final lights = (args['lightPaths'] as List).cast<String>();
    final output = args['output'] as Map<String, dynamic>;
    return IntegrateSessionResult(
      masterFitsPath: output['masterFitsPath'] as String,
      previewPath: output['previewPngPath'] as String?,
      rejectionMapPath: output['rejectionMapPath'] as String?,
      rejectionMapPreviewPath: output['rejectionMapPreviewPath'] as String?,
      framesIntegrated: lights.length,
      framesRejected: 0,
      totalIntegrationSec: 0.0,
      rmsResidual: 0.42,
      width: 100,
      height: 80,
      channels: 1,
      perFrameStats: [
        for (final p in lights)
          PerFrameRecord(
            path: p,
            weight: 1.0,
            rmsResidualPx: 0.4,
            accepted: true,
            reason: null,
          ),
      ],
    );
  }

  @override
  Future<MasterAccumulateResult> masterAccumulate(
    Map<String, dynamic> args,
  ) async {
    accumulateCalls.add(args);
    final op = args['op'] as String;
    final queue = scriptedAccumulate[op];
    if (queue != null && queue.isNotEmpty) {
      return queue.removeAt(0);
    }
    // Reasonable default echo.
    final added = (args['lightPaths'] as List?)?.length ?? 0;
    return MasterAccumulateResult(
      sidecarPath: args['sidecarPath'] as String? ?? '',
      masterPath: args['masterFitsPath'] as String?,
      previewPath: args['previewPngPath'] as String?,
      frameCount: added,
      totalIntegrationSec: 0.0,
      width: 100,
      height: 80,
      channels: 1,
      framesAdded: added,
      rejected: 0,
    );
  }

  @override
  Future<BuildMasterFlatResult> buildMasterFlat(
    Map<String, dynamic> args,
  ) async {
    flatCalls.add(args);
    return BuildMasterFlatResult(
      outputPath: args['outputPath'] as String,
      frameCount: (args['flatPaths'] as List).length,
      inputMean: 30000.0,
      outputMean: 1.0,
      width: 100,
      height: 80,
      channels: 1,
      outputBitDepth: args['outputBitDepth'] as String? ?? 'f32',
    );
  }

  @override
  Future<SaveFitsMasterResult> saveFitsMaster(Map<String, dynamic> args) async {
    return SaveFitsMasterResult(
      outputPath: args['outputPath'] as String,
      width: args['width'] as int? ?? 0,
      height: args['height'] as int? ?? 0,
      channels: args['channels'] as int? ?? 1,
      pixelType: args['pixelType'] as String? ?? 'f32',
    );
  }

  // Smart Morning Report finishing seam (scriptable)

  /// Scripted [analyzeNight] result; defaults to an empty curve.
  IntegrationCurve analyzeResult = IntegrationCurve.empty;

  /// Records every [analyzeNight] invocation's inputs.
  final List<
    ({
      List<Map<String, dynamic>> qualities,
      List<double> weights,
      List<double> exposuresS,
    })
  >
  analyzeCalls = [];

  /// Records the args of every optional finishing-step call, keyed by step name.
  final Map<String, List<Map<String, dynamic>>> finishingCalls = {
    'extractBackground': [],
    'reduceStarsPreview': [],
    'deconvolvePreview': [],
    'colorCalibrate': [],
  };

  /// Scripted [detectStarsPhotometry] result; defaults to an empty result.
  StarPhotometryResult photometryResult = StarPhotometryResult.empty;

  /// Scripted [colorCalibrate] result; defaults to an identity calibration that
  /// echoes the requested output path.
  ColorCalibrationResult? colorResult;

  /// Synthetic progress events the fake [integrationProgress] stream replays.
  List<({String phase, double fraction})> progressEvents = const [];

  /// When true, [analyzeNight] computes the curve with a faithful port of the
  /// native optimizer (`integration_curve`, `optimizer.rs`) over the qualities
  /// it is actually handed — instead of returning the canned [analyzeResult].
  /// This makes the morning-report wiring testable end-to-end: a `qualities`
  /// map that omits `noise` yields the same all-zero curve the real Rust
  /// optimizer would (it skips any `noise <= 0` sub from its variance sums), so
  /// a dead improvement curve cannot be masked by a fake one.
  bool useRealOptimizer = false;

  @override
  Future<IntegrationCurve> analyzeNight({
    required List<Map<String, dynamic>> qualities,
    required List<double> weights,
    required List<double> exposuresS,
    double? aggressiveness,
    int? minKeep,
  }) async {
    analyzeCalls.add((
      qualities: qualities,
      weights: weights,
      exposuresS: exposuresS,
    ));
    if (useRealOptimizer) {
      return _realIntegrationCurve(qualities, weights, exposuresS);
    }
    return analyzeResult;
  }

  /// Faithful Dart port of `optimizer.rs::integration_curve`: rank subs by
  /// weight desc, then sweep the prefix accumulating signal = snr·noise and
  /// variance = noise² ONLY for subs with finite `noise > 0` and `weight > 0`.
  /// SNR = ΣwΒ·signal / sqrt(Σw²·variance). The point of porting (rather than
  /// fabricating) is that the `noise > 0` gate is exactly the one that kills the
  /// real curve when `_analyzeAndStoreCurve` forgets to forward `noise`.
  static IntegrationCurve _realIntegrationCurve(
    List<Map<String, dynamic>> qualities,
    List<double> weights,
    List<double> exposuresS,
  ) {
    final n = qualities.length;
    if (n == 0) return IntegrationCurve.empty;
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => weights[b].compareTo(weights[a]));

    var sumSignal = 0.0;
    var sumVar = 0.0;
    var sumWFwhm = 0.0;
    var sumWForFwhm = 0.0;
    var cumExposure = 0.0;
    final points = <IntegrationCurvePoint>[];
    for (var rank = 0; rank < order.length; rank++) {
      final idx = order[rank];
      final q = qualities[idx];
      final w = weights[idx] <= 0 ? 0.0 : weights[idx];
      final noise = (q['noise'] as num?)?.toDouble() ?? 0.0;
      final snr = (q['snr'] as num?)?.toDouble() ?? 0.0;
      if (noise.isFinite && noise > 0.0 && w > 0.0) {
        final signal = (snr < 0 ? 0.0 : snr) * noise;
        sumSignal += w * signal;
        sumVar += w * w * noise * noise;
      }
      final fwhm = (q['fwhm'] as num?)?.toDouble() ?? 0.0;
      if (fwhm.isFinite && fwhm > 0.0 && w > 0.0) {
        sumWFwhm += w * fwhm;
        sumWForFwhm += w;
      }
      cumExposure += (idx < exposuresS.length ? exposuresS[idx] : 0.0).clamp(
        0.0,
        double.infinity,
      );
      points.add(
        IntegrationCurvePoint(
          n: rank + 1,
          snr: sumVar > 0 ? sumSignal / math.sqrt(sumVar) : 0.0,
          fwhm: sumWForFwhm > 0 ? sumWFwhm / sumWForFwhm : 0.0,
          cumulativeIntegrationS: cumExposure,
        ),
      );
    }
    return IntegrationCurve(
      points: points,
      recommendation: SubsetRecommendation(
        keepN: points.length,
        keptIndices: order,
        predictedSnrGainPct: 0.0,
        reason: 'keep all',
      ),
    );
  }

  @override
  Future<StarPhotometryResult> detectStarsPhotometry({
    required String inputFits,
    int? maxStars,
    int? aperture,
  }) async => photometryResult;

  @override
  Future<ColorCalibrationResult> colorCalibrate({
    required String inputFits,
    required String outputFits,
    required int channels,
    double? whiteRefBv,
    required List<Map<String, dynamic>> matchedStars,
  }) async {
    finishingCalls['colorCalibrate']!.add(<String, dynamic>{
      'inputFits': inputFits,
      'outputFits': outputFits,
      'channels': channels,
    });
    return colorResult ??
        ColorCalibrationResult(
          outputPath: outputFits,
          channelScale: List<double>.filled(channels, 1.0),
          matched: matchedStars.length,
          residual: 0.0,
        );
  }

  @override
  Future<String> extractBackground(Map<String, dynamic> args) async {
    finishingCalls['extractBackground']!.add(args);
    return args['outputFits'] as String? ?? args['outputPath'] as String? ?? '';
  }

  @override
  Future<String> deconvolvePreview(Map<String, dynamic> args) async {
    finishingCalls['deconvolvePreview']!.add(args);
    return args['outputFits'] as String? ?? args['outputPath'] as String? ?? '';
  }

  @override
  Future<String> reduceStarsPreview(Map<String, dynamic> args) async {
    finishingCalls['reduceStarsPreview']!.add(args);
    return args['outputFits'] as String? ?? args['outputPath'] as String? ?? '';
  }

  /// Records every [drizzleIntegrate] invocation's args.
  final List<Map<String, dynamic>> drizzleCalls = [];

  @override
  Future<Map<String, dynamic>> drizzleIntegrate(
    Map<String, dynamic> args,
  ) async {
    drizzleCalls.add(args);
    final scale =
        ((args['config'] as Map?)?['scale'] as num?)?.toDouble() ?? 2.0;
    final refW = (args['refW'] as num?)?.toInt() ?? 0;
    final refH = (args['refH'] as num?)?.toInt() ?? 0;
    return <String, dynamic>{
      'outputPath': args['outputFits'] as String? ?? '',
      'coveragePath': args['coverageFits'],
      'coveragePngPath': args['coveragePngPath'],
      'previewPngPath': args['previewPngPath'],
      'outWidth': (refW * scale).ceil(),
      'outHeight': (refH * scale).ceil(),
      'channels': (args['bayer'] as bool? ?? false) ? 3 : 1,
    };
  }

  @override
  Future<String> combineChannels(Map<String, dynamic> args) async =>
      args['outputFits'] as String? ?? args['outputPath'] as String? ?? '';

  /// Records every [stitchMosaic] invocation's args.
  final List<Map<String, dynamic>> stitchCalls = [];

  /// Scripted [stitchMosaic] result; when null the fake echoes the requested
  /// output paths with a synthetic canvas size derived from the panel count.
  MosaicStitchResult? stitchResult;

  @override
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async {
    stitchCalls.add(args);
    if (stitchResult != null) return stitchResult!;
    final output =
        (args['output'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final panels = (args['panels'] as List?)?.length ?? 0;
    return MosaicStitchResult(
      outputPath: output['mosaicFitsPath'] as String? ?? '',
      coveragePath: output['coverageFitsPath'] as String?,
      previewPath: output['previewPngPath'] as String?,
      outWidth: 100 * panels,
      outHeight: 80,
      overlapPairs: panels > 1 ? panels - 1 : 0,
      meanPanelGain: 1.0,
    );
  }

  @override
  Stream<({String phase, double fraction})> integrationProgress() =>
      Stream.fromIterable(progressEvents);
}

void main() {
  test(
    'native integration result decodes scientific and display map paths',
    () {
      final result = IntegrateSessionResult.fromJson(const {
        'masterFitsPath': '/out/master.fits',
        'previewPath': '/out/master.png',
        'rejectionMapPath': '/out/master_rejmap.fits',
        'rejectionMapPreviewPath': '/out/master_rejmap.png',
        'coverageMapPath': '/out/master_cov.fits',
        'coverageMapPreviewPath': '/out/master_cov.png',
        'framesIntegrated': 3,
        'framesRejected': 1,
        'totalIntegrationSec': 180.0,
        'rmsResidual': 0.4,
        'width': 100,
        'height': 80,
        'channels': 1,
        'perFrameStats': <Map<String, Object?>>[],
      });

      expect(result.rejectionMapPath, '/out/master_rejmap.fits');
      expect(result.rejectionMapPreviewPath, '/out/master_rejmap.png');
      expect(result.coverageMapPath, '/out/master_cov.fits');
      expect(result.coverageMapPreviewPath, '/out/master_cov.png');
    },
  );

  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late IntegratedMastersDao mastersDao;
  late FlatLibraryDao flatDao;
  late DarkLibraryService darkLibrary;
  late CalibrationLibraryService calibrationLibrary;
  late FakePostSessionSeam seam;
  late PostSessionIntegrationService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = db.imagesDao;
    mastersDao = IntegratedMastersDao(db);
    flatDao = FlatLibraryDao(db);
    darkLibrary = DarkLibraryService(DarkLibraryDao(db));
    seam = FakePostSessionSeam();
    calibrationLibrary = CalibrationLibraryService(
      db: db,
      flatLibraryDao: flatDao,
      tagsDao: CalibrationTagsDao(db),
    );
    service = PostSessionIntegrationService(
      mastersDao: mastersDao,
      calibrationLibrary: calibrationLibrary,
      seam: seam,
    );
  });

  tearDown(() async {
    await db.close();
  });

  /// Inserts one accepted light sub. [gain] / [offset] accept null to model the
  /// real nullable columns — a camera or driver that never reported them.
  Future<CapturedImage> insertSub({
    required String path,
    String? filter,
    double quality = 80.0,
    double hfr = 2.0,
    int? gain = 100,
    int? offset = 10,
    DateTime? capturedAt,
  }) async {
    final id = await db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: path,
            fileName: path.split('/').last,
            frameType: const Value('light'),
            exposureDuration: 120.0,
            capturedAt: capturedAt ?? DateTime(2026, 6, 7, 22),
            gain: Value(gain),
            offset: Value(offset),
            binX: const Value(1),
            binY: const Value(1),
            filter: Value(filter),
            sensorTemp: const Value(-10.0),
            hfr: Value(hfr),
            qualityScore: Value(quality),
            isAccepted: const Value(true),
          ),
        );
    return (await imagesDao.getImageById(id))!;
  }

  test(
    'integrate persists a finalized master + fold records per sub',
    () async {
      final subs = [
        await insertSub(path: '/lights/a.fits', filter: 'L', quality: 90),
        await insertSub(path: '/lights/b.fits', filter: 'L', quality: 70),
        await insertSub(path: '/lights/c.fits', filter: 'L', quality: 60),
      ];

      final outcomes = await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        targetId: null,
        targetName: 'M51',
        outputFitsPathBuilder: (bucket) => '/out/master_$bucket.fits',
      );

      expect(outcomes, hasLength(1));
      final outcome = outcomes.single;
      expect(outcome.filter, 'L');
      expect(outcome.result.framesIntegrated, 3);

      // The seam received one integrate call with the right shape.
      expect(seam.integrateCalls, hasLength(1));
      final args = seam.integrateCalls.single;
      expect(
        (args['lightPaths'] as List).cast<String>(),
        containsAll(['/lights/a.fits', '/lights/b.fits', '/lights/c.fits']),
      );
      // Highest-quality sub (a, q=90) becomes the explicit reference.
      expect(args['reference'], '/lights/a.fits');
      expect((args['settings'] as Map).containsKey('align'), isTrue);

      // Master row persisted, finalized, batch mode.
      final master = await mastersDao.getById(outcome.masterId);
      expect(master, isNotNull);
      expect(master!.status, IntegratedMasterStatus.finalized);
      expect(master.accumulationMode, AccumulationMode.batch);
      expect(master.filter, 'L');
      expect(master.frameCount, 3);
      expect(master.name, 'M51 · L');
      expect(master.masterFitsPath, '/out/master_L.fits');

      // One fold record per sub.
      final folded = await mastersDao.getFoldedImageIds(outcome.masterId);
      expect(folded, subs.map((s) => s.id).toSet());
    },
  );

  test('integrate makes one master per filter group', () async {
    final subs = [
      await insertSub(path: '/l/a.fits', filter: 'Ha'),
      await insertSub(path: '/l/b.fits', filter: 'OIII'),
      await insertSub(path: '/l/c.fits', filter: 'Ha'),
    ];

    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults,
      outputFitsPathBuilder: (bucket) => '/out/$bucket.fits',
    );

    final byFilter = {for (final o in outcomes) o.filter: o};
    expect(byFilter.keys.toSet(), {'Ha', 'OIII'});
    expect(byFilter['Ha']!.result.framesIntegrated, 2);
    expect(byFilter['OIII']!.result.framesIntegrated, 1);
    expect(seam.integrateCalls, hasLength(2));
  });

  test(
    'a pass is planned, tagged per lane and ended for the pass view',
    () async {
      final reporter = _RecordingReporter();
      final reported = PostSessionIntegrationService(
        mastersDao: mastersDao,
        calibrationLibrary: calibrationLibrary,
        seam: seam,
        passReporter: reporter,
      );
      final subs = [
        await insertSub(path: '/l/a.fits', filter: 'L'),
        await insertSub(path: '/l/b.fits', filter: 'R'),
        await insertSub(path: '/l/c.fits', filter: 'L'),
      ];
      await reported.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (bucket) => '/out/$bucket.fits',
        runId: 'post-session-9',
        sessionId: 9,
        targetName: 'M31',
      );

      final kinds = reporter.reports.map((r) => r.$2).toList();
      expect(kinds.first, PassKinds.passPlanned);
      expect(kinds.last, PassKinds.passEnded);
      expect(kinds.where((k) => k == PassKinds.laneFinished), hasLength(2));
      final plan = reporter.reports.first.$3;
      expect(plan['sessionId'], 9);
      expect(plan['target'], 'M31');
      expect((plan['lanes'] as List).map((l) => (l as Map)['lane']), [
        'L',
        'R',
      ]);
      expect(reporter.reports.every((r) => r.$1 == 'post-session-9'), isTrue);

      final args = seam.integrateCalls.first;
      expect(args['runId'], 'post-session-9');
      expect(args['telemetry'], {
        'lane': 'L',
        'previewDir': '/previews/post-session-9',
      });
    },
  );

  test('a pass the caller keeps open is not ended, and a call without a run '
      'id still reports under one of its own', () async {
    final reporter = _RecordingReporter();
    final reported = PostSessionIntegrationService(
      mastersDao: mastersDao,
      calibrationLibrary: calibrationLibrary,
      seam: seam,
      passReporter: reporter,
    );
    await reported.integrate(
      subs: [await insertSub(path: '/l/a.fits', filter: 'L')],
      settings: IntegrationSettings.defaults,
      outputFitsPathBuilder: (bucket) => '/out/$bucket.fits',
      closePass: false,
    );
    expect(
      reporter.reports.map((r) => r.$2),
      isNot(contains(PassKinds.passEnded)),
    );
    expect(reporter.reports.first.$1, startsWith('integrate-'));
    expect(seam.integrateCalls.single['runId'], reporter.reports.first.$1);
  });

  test(
    'resolved calibration feeds matched dark + flat paths to the seam',
    () async {
      // Register a matching master dark and master flat.
      await darkLibrary.createMasterDarkEntryForTest(db);
      await flatDao.addEntry(
        filePath: '/cal/master_flat_L.fits',
        filter: 'L',
        gain: 100,
        offset: 10,
        binX: 1,
        binY: 1,
        temperature: -10.0,
      );

      final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];
      await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (bucket) => '/out/$bucket.fits',
      );

      final calibration =
          seam.integrateCalls.single['calibration'] as Map<String, dynamic>;
      expect(calibration['flat'], '/cal/master_flat_L.fits');
      expect(calibration['dark'], '/cal/master_dark.fits');
      expect(calibration['cosmeticCorrection'], isTrue);
    },
  );

  test(
    'an unmatched master surfaces the library matcher warning on the outcome '
    '(no unwarned calibration path exists)',
    () async {
      // No masters registered at all: both types miss.
      final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];
      final outcomes = await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (bucket) => '/out/$bucket.fits',
      );

      final warnings = outcomes.single.calibrationWarnings;
      expect(warnings, hasLength(2));
      expect(warnings.first, contains('No matching master dark'));
      expect(warnings.last, contains('No matching master flat for filter L'));

      final calibration =
          seam.integrateCalls.single['calibration'] as Map<String, dynamic>;
      expect(calibration.containsKey('dark'), isFalse);
      expect(calibration.containsKey('flat'), isFalse);
    },
  );

  test('a sub with no recorded gain still matches the library masters and the '
      'outcome marks the dimension unverified', () async {
    // Both masters were shot at gain 100 / offset 10. The sub carries no
    // gain: comparing that against a fabricated 0 would have missed both and
    // silently skipped dark + flat correction.
    await darkLibrary.createMasterDarkEntryForTest(db);
    await flatDao.addEntry(
      filePath: '/cal/master_flat_L.fits',
      filter: 'L',
      gain: 100,
      offset: 10,
      binX: 1,
      binY: 1,
      temperature: -10.0,
    );

    final subs = [await insertSub(path: '/l/a.fits', filter: 'L', gain: null)];
    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults,
      outputFitsPathBuilder: (bucket) => '/out/$bucket.fits',
    );

    final calibration =
        seam.integrateCalls.single['calibration'] as Map<String, dynamic>;
    expect(calibration['dark'], '/cal/master_dark.fits');
    expect(calibration['flat'], '/cal/master_flat_L.fits');

    // The applied-masters account states the dimension it could not compare
    // instead of reading like an exact match.
    final warnings = outcomes.single.calibrationWarnings;
    expect(
      warnings.where((w) => w.contains('record no gain')),
      hasLength(2),
      reason: 'both the dark and the flat pick report the unverified gain',
    );
    expect(warnings.any((w) => w.contains('gain 0')), isFalse);

    // …and it survives into stats_json, which the dawn autopilot and the
    // morning report read back.
    final master = await mastersDao.getById(outcomes.single.masterId);
    final stats = jsonDecode(master!.statsJson) as Map<String, dynamic>;
    expect(
      (stats['calibrationWarnings'] as List).cast<String>().any(
        (w) => w.contains('record no gain'),
      ),
      isTrue,
    );
  });

  test(
    'a sub with no recorded gain does not match a master of another offset',
    () async {
      // The library's only dark is at offset 10; the sub records offset 99.
      // The unknown gain drops out of the comparison, the recorded offset does
      // not.
      await darkLibrary.createMasterDarkEntryForTest(db);

      final subs = [
        await insertSub(path: '/l/a.fits', filter: 'L', gain: null, offset: 99),
      ];
      final outcomes = await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (bucket) => '/out/$bucket.fits',
      );

      final calibration =
          seam.integrateCalls.single['calibration'] as Map<String, dynamic>;
      expect(calibration.containsKey('dark'), isFalse);
      expect(
        outcomes.single.calibrationWarnings.any(
          (w) => w.contains('No matching master dark'),
        ),
        isTrue,
      );
    },
  );

  test('empty subs is a hard error, not a silent no-op', () async {
    expect(
      () => service.integrate(
        subs: const [],
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (_) => '/out/x.fits',
      ),
      throwsArgumentError,
    );
  });

  test(
    'rejection map / preview paths are derived from the master path',
    () async {
      final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];
      await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );
      final output =
          seam.integrateCalls.single['output'] as Map<String, dynamic>;
      expect(output['masterFitsPath'], '/out/master.fits');
      expect(output['previewPngPath'], '/out/master.png');
      expect(output['rejectionMapPath'], '/out/master_rejmap.fits');
      expect(output['rejectionMapPreviewPath'], '/out/master_rejmap.png');
    },
  );

  // Smart Morning Report extensions

  /// An integrate builder that echoes the lights and stamps each accepted
  /// per-frame record with synthetic per-sub science metrics.
  void scriptMetrics() {
    seam.integrateBuilder = (args) {
      final lights = (args['lightPaths'] as List).cast<String>();
      final output = args['output'] as Map<String, dynamic>;
      return IntegrateSessionResult(
        masterFitsPath: output['masterFitsPath'] as String,
        previewPath: output['previewPngPath'] as String?,
        rejectionMapPath: output['rejectionMapPath'] as String?,
        rejectionMapPreviewPath: output['rejectionMapPreviewPath'] as String?,
        framesIntegrated: lights.length,
        framesRejected: 0,
        totalIntegrationSec: 120.0 * lights.length,
        rmsResidual: 0.42,
        width: 100,
        height: 80,
        channels: 1,
        perFrameStats: [
          for (var i = 0; i < lights.length; i++)
            PerFrameRecord(
              path: lights[i],
              weight: 1.0,
              rmsResidualPx: 0.4,
              accepted: true,
              reason: null,
              snr: 40.0 + i,
              // Real per-sub noise so the optimizer has an honest variance term.
              noise: 5.0 + i * 0.5,
              background: 1000.0 + i * 10,
              starCount: 120 + i,
              fwhm: 2.5 + i * 0.1,
              eccentricity: 0.3,
            ),
        ],
      );
    };
  }

  test(
    'per-sub snr/fwhm/eccentricity are persisted on the fold records',
    () async {
      scriptMetrics();
      final subs = [
        await insertSub(path: '/l/a.fits', filter: 'L'),
        await insertSub(path: '/l/b.fits', filter: 'L'),
      ];

      final outcomes = await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );
      final masterId = outcomes.single.masterId;

      // Read the v42 per-sub columns straight from integrated_master_frames.
      final rows = await db
          .customSelect(
            'SELECT image_id, snr, fwhm, eccentricity FROM integrated_master_frames '
            'WHERE master_id = ? ORDER BY image_id ASC',
            variables: [Variable<int>(masterId)],
          )
          .get();
      expect(rows, hasLength(2));
      final byImage = {
        for (final r in rows)
          r.read<int>('image_id'): (
            snr: r.readNullable<double>('snr'),
            fwhm: r.readNullable<double>('fwhm'),
            ecc: r.readNullable<double>('eccentricity'),
          ),
      };
      expect(byImage[subs[0].id]!.snr, 40.0);
      expect(byImage[subs[0].id]!.fwhm, 2.5);
      expect(byImage[subs[0].id]!.ecc, 0.3);
      expect(byImage[subs[1].id]!.snr, 41.0);
    },
  );

  test(
    'analyzeNight is invoked and improvement_curve_json + target fields stored',
    () async {
      scriptMetrics();
      seam.analyzeResult = const IntegrationCurve(
        points: [
          IntegrationCurvePoint(
            n: 1,
            snr: 40.0,
            fwhm: 2.5,
            cumulativeIntegrationS: 120.0,
          ),
          IntegrationCurvePoint(
            n: 2,
            snr: 56.0,
            fwhm: 2.55,
            cumulativeIntegrationS: 240.0,
          ),
        ],
        recommendation: SubsetRecommendation(
          keepN: 2,
          keptIndices: [0, 1],
          predictedSnrGainPct: 0.0,
          reason: 'keep all',
        ),
      );

      final subs = [
        await insertSub(path: '/l/a.fits', filter: 'L'),
        await insertSub(path: '/l/b.fits', filter: 'L'),
      ];
      final outcomes = await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );
      final masterId = outcomes.single.masterId;

      // analyzeNight saw one call carrying the per-sub qualities + weights.
      expect(seam.analyzeCalls, hasLength(1));
      final call = seam.analyzeCalls.single;
      expect(call.qualities, hasLength(2));
      expect(call.qualities.first['snr'], 40.0);
      expect(call.weights, [1.0, 1.0]);

      // The curve + full-night anchor landed in the v42 smart columns.
      final row =
          (await db
                  .customSelect(
                    'SELECT improvement_curve_json, target_snr, target_integration_s '
                    'FROM integrated_masters WHERE id = ?',
                    variables: [Variable<int>(masterId)],
                  )
                  .get())
              .single;
      final curveJson = row.read<String>('improvement_curve_json');
      final decoded = IntegrationCurve.fromJson(
        jsonDecode(curveJson) as Map<String, dynamic>,
      );
      expect(decoded.points, hasLength(2));
      expect(decoded.recommendation.keepN, 2);
      // target_snr / target_integration_s anchor to the full-night curve point.
      expect(row.read<double>('target_snr'), 56.0);
      expect(row.read<double>('target_integration_s'), 240.0);
    },
  );

  test('REGRESSION #5: the qualities map carries per-sub noise so the REAL '
      'optimizer yields a positive, monotone curve + non-zero target_snr', () async {
    scriptMetrics();
    // Drive the FAITHFUL optimizer port (not a canned curve), so the curve is
    // whatever `_analyzeAndStoreCurve`'s qualities support. Without `noise` in
    // the map every point's snr is 0 and the anchor (target_snr) is 0.
    seam.useRealOptimizer = true;

    final subs = [
      await insertSub(path: '/l/a.fits', filter: 'L'),
      await insertSub(path: '/l/b.fits', filter: 'L'),
      await insertSub(path: '/l/c.fits', filter: 'L'),
    ];
    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults,
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );
    final masterId = outcomes.single.masterId;

    // The qualities map the service handed the optimizer must carry `noise` for
    // every sub — the field whose absence kills the curve.
    final call = seam.analyzeCalls.single;
    expect(call.qualities, hasLength(3));
    for (final q in call.qualities) {
      expect(
        q.containsKey('noise'),
        isTrue,
        reason: 'each quality descriptor must forward per-sub noise',
      );
      expect((q['noise'] as num) > 0, isTrue);
    }

    // The persisted curve is POSITIVE and monotone-non-decreasing, and the
    // anchored target_snr is strictly > 0 (the value the deficit loop needs).
    final row =
        (await db
                .customSelect(
                  'SELECT improvement_curve_json, target_snr FROM integrated_masters '
                  'WHERE id = ?',
                  variables: [Variable<int>(masterId)],
                )
                .get())
            .single;
    final decoded = IntegrationCurve.fromJson(
      jsonDecode(row.read<String>('improvement_curve_json'))
          as Map<String, dynamic>,
    );
    expect(decoded.points, hasLength(3));
    var prev = -1.0;
    for (final pt in decoded.points) {
      expect(
        pt.snr,
        greaterThan(0.0),
        reason: 'a real noise-driven curve must be positive, not all-zero',
      );
      expect(
        pt.snr,
        greaterThanOrEqualTo(prev - 1e-9),
        reason: 'curve must be monotone-non-decreasing',
      );
      prev = pt.snr;
    }
    final targetSnr = row.read<double>('target_snr');
    expect(
      targetSnr,
      greaterThan(0.0),
      reason: 'target_snr anchors the deficit loop; it must be non-zero',
    );
  });

  test('CONTROL: without per-sub noise the REAL optimizer collapses to a '
      'zero curve (proves the regression test bites)', () async {
    // A metrics scripter that deliberately OMITS noise.
    seam.integrateBuilder = (args) {
      final lights = (args['lightPaths'] as List).cast<String>();
      final output = args['output'] as Map<String, dynamic>;
      return IntegrateSessionResult(
        masterFitsPath: output['masterFitsPath'] as String,
        previewPath: output['previewPngPath'] as String?,
        rejectionMapPath: output['rejectionMapPath'] as String?,
        rejectionMapPreviewPath: output['rejectionMapPreviewPath'] as String?,
        framesIntegrated: lights.length,
        framesRejected: 0,
        totalIntegrationSec: 120.0 * lights.length,
        rmsResidual: 0.42,
        width: 100,
        height: 80,
        channels: 1,
        perFrameStats: [
          for (final pth in lights)
            PerFrameRecord(
              path: pth,
              weight: 1.0,
              rmsResidualPx: 0.4,
              accepted: true,
              reason: null,
              snr: 40.0, // snr present, noise absent → variance term is 0.
              fwhm: 2.5,
              eccentricity: 0.3,
            ),
        ],
      );
    };
    seam.useRealOptimizer = true;

    final subs = [
      await insertSub(path: '/l/a.fits', filter: 'L'),
      await insertSub(path: '/l/b.fits', filter: 'L'),
    ];
    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults,
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );
    final row =
        (await db
                .customSelect(
                  'SELECT improvement_curve_json, target_snr FROM integrated_masters '
                  'WHERE id = ?',
                  variables: [Variable<int>(outcomes.single.masterId)],
                )
                .get())
            .single;
    final decoded = IntegrationCurve.fromJson(
      jsonDecode(row.read<String>('improvement_curve_json'))
          as Map<String, dynamic>,
    );
    // Every point is zero and the anchor is zero — the exact dead feature.
    expect(decoded.points.every((p) => p.snr == 0.0), isTrue);
    expect(row.read<double>('target_snr'), 0.0);
  });

  test('optional finishing steps are gated by the settings knobs', () async {
    scriptMetrics();
    final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];

    // All optional knobs OFF: no finishing call fires.
    await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults.copyWith(
        extractBackground: false,
        colorCalibrate: false,
        reduceStars: false,
        deconvolve: false,
      ),
      outputFitsPathBuilder: (_) => '/out/off.fits',
    );
    expect(seam.finishingCalls['extractBackground'], isEmpty);
    expect(seam.finishingCalls['reduceStarsPreview'], isEmpty);
    expect(seam.finishingCalls['deconvolvePreview'], isEmpty);

    // Knobs ON: background + star-reduction + deconvolution each fire once
    // against the master FITS. Colour calibration stays skipped (no
    // ColorCalibrationService wired), so its seam method is never called.
    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults.copyWith(
        extractBackground: true,
        colorCalibrate: true,
        reduceStars: true,
        deconvolve: true,
      ),
      outputFitsPathBuilder: (_) => '/out/on.fits',
    );
    expect(seam.finishingCalls['extractBackground'], hasLength(1));
    expect(
      seam.finishingCalls['extractBackground']!.single['inputFits'],
      '/out/on.fits',
    );
    expect(seam.finishingCalls['reduceStarsPreview'], hasLength(1));
    expect(seam.finishingCalls['deconvolvePreview'], hasLength(1));
    expect(seam.finishingCalls['colorCalibrate'], isEmpty);

    // background_extracted flips to 1 once extraction ran.
    final row =
        (await db
                .customSelect(
                  'SELECT background_extracted, background_extracted_path, '
                  'deconvolved_path, star_reduced_path '
                  'FROM integrated_masters WHERE id = ?',
                  variables: [Variable<int>(outcomes.single.masterId)],
                )
                .get())
            .single;
    expect(row.read<int>('background_extracted'), 1);

    // Each pass's written FITS path is persisted via updateFinishingPaths onto
    // the v44 columns. The fake seam echoes `outputFits`, and the service
    // suffixes the master path with _bgx/_decon/_starred.
    expect(row.read<String>('background_extracted_path'), '/out/on_bgx.fits');
    expect(row.read<String>('deconvolved_path'), '/out/on_decon.fits');
    expect(row.read<String>('star_reduced_path'), '/out/on_starred.fits');

    // The DAO mapper round-trips the same paths onto the typed model.
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master!.backgroundExtractedPath, '/out/on_bgx.fits');
    expect(master.deconvolvedPath, '/out/on_decon.fits');
    expect(master.starReducedPath, '/out/on_starred.fits');
  });

  test('finishing paths stay null when their knobs are off', () async {
    scriptMetrics();
    final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];
    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults.copyWith(
        extractBackground: false,
        reduceStars: false,
        deconvolve: false,
      ),
      outputFitsPathBuilder: (_) => '/out/off.fits',
    );
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master!.backgroundExtractedPath, isNull);
    expect(master.deconvolvedPath, isNull);
    expect(master.starReducedPath, isNull);
  });

  // Drizzle branch

  /// An integrate builder that echoes the lights and stamps each accepted
  /// per-frame record with a (non-identity) source→reference registration
  /// transform — the input the drizzle branch needs.
  void scriptMetricsWithTransforms() {
    seam.integrateBuilder = (args) {
      final lights = (args['lightPaths'] as List).cast<String>();
      final output = args['output'] as Map<String, dynamic>;
      return IntegrateSessionResult(
        masterFitsPath: output['masterFitsPath'] as String,
        previewPath: output['previewPngPath'] as String?,
        rejectionMapPath: output['rejectionMapPath'] as String?,
        rejectionMapPreviewPath: output['rejectionMapPreviewPath'] as String?,
        framesIntegrated: lights.length,
        framesRejected: 0,
        totalIntegrationSec: 120.0 * lights.length,
        rmsResidual: 0.42,
        width: 100,
        height: 80,
        channels: 1,
        perFrameStats: [
          for (var i = 0; i < lights.length; i++)
            PerFrameRecord(
              path: lights[i],
              weight: 0.9 + i * 0.01,
              rmsResidualPx: 0.4,
              accepted: true,
              reason: null,
              snr: 40.0 + i,
              fwhm: 2.5,
              eccentricity: 0.3,
              // A small translation per sub, identity rotation/scale.
              transform: [1.0, 0.0, i.toDouble(), 0.0, 1.0, 0.0, 0.0, 0.0, 1.0],
              transformKind: 'similarity',
            ),
        ],
      );
    };
  }

  test('drizzle branch is NOT invoked when the knob is off', () async {
    scriptMetricsWithTransforms();
    final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];

    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults.copyWith(drizzle: false),
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );

    expect(seam.drizzleCalls, isEmpty);
    // The standard master FITS stays the master.
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master!.masterFitsPath, '/out/master.fits');
  });

  test('drizzle branch is invoked when enabled, feeding per-sub transforms + '
      'config, and swaps the drizzled FITS in as the master', () async {
    scriptMetricsWithTransforms();
    final subs = [
      await insertSub(path: '/l/a.fits', filter: 'L'),
      await insertSub(path: '/l/b.fits', filter: 'L'),
    ];

    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults.copyWith(
        drizzle: true,
        drizzleScale: 2.0,
        drizzlePixfrac: 0.8,
        drizzleKernel: DrizzleKernel.gaussian,
        bayerDrizzle: false,
      ),
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );

    // The drizzle seam saw exactly one call.
    expect(seam.drizzleCalls, hasLength(1));
    final call = seam.drizzleCalls.single;

    // Output derived from the master path; reference grid = the standard dims.
    expect(call['outputFits'], '/out/master_drizzle.fits');
    expect(call['refW'], 100);
    expect(call['refH'], 80);
    expect(call['bayer'], isFalse);
    // A sibling preview PNG path for the drizzled master is requested.
    expect(call['previewPngPath'], '/out/master_drizzle.png');
    expect(call['coverageFits'], '/out/master_drizzle_cov.fits');
    expect(call['coveragePngPath'], '/out/master_drizzle_cov.png');

    // Config mirrors the settings knobs.
    final config = call['config'] as Map<String, dynamic>;
    expect(config['scale'], 2.0);
    expect(config['pixfrac'], 0.8);
    expect(config['kernel'], 'gaussian');

    // One frame per accepted sub, each carrying its 9-element transform + weight.
    final frames = (call['frames'] as List).cast<Map<String, dynamic>>();
    expect(frames, hasLength(2));
    expect(frames[0]['fitsPath'], '/l/a.fits');
    expect((frames[0]['transform'] as List), hasLength(9));
    expect(frames[1]['fitsPath'], '/l/b.fits');
    expect((frames[1]['transform'] as List)[2], 1.0); // per-sub translation.

    // The drizzled FITS + its preview are swapped in as the persisted master,
    // with the scaled (2×) dimensions.
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master!.masterFitsPath, '/out/master_drizzle.fits');
    expect(master.previewPngPath, '/out/master_drizzle.png');
    expect(master.rejectionMapPath, '/out/master_rejmap.fits');
    expect(master.rejectionMapPreviewPath, '/out/master_rejmap.png');
    expect(master.coverageMapPath, '/out/master_drizzle_cov.fits');
    expect(master.coverageMapPreviewPath, '/out/master_drizzle_cov.png');
    expect(master.width, 200);
    expect(master.height, 160);
    // The returned outcome result reflects the drizzled master + preview too, so
    // the immediate post-integrate hero shows the drizzled image, not the 1×.
    expect(outcomes.single.result.masterFitsPath, '/out/master_drizzle.fits');
    expect(outcomes.single.result.previewPath, '/out/master_drizzle.png');
    expect(
      outcomes.single.result.coverageMapPreviewPath,
      '/out/master_drizzle_cov.png',
    );
    expect(outcomes.single.result.width, 200);
  });

  test(
    'REGRESSION #4: drizzle is handed the SAME resolved calibration the '
    'standard integrate path used (so the drizzled master stays calibrated)',
    () async {
      scriptMetricsWithTransforms();

      // Register a matching master dark + master flat so calibration resolves to
      // real paths (the same ones the integrate call receives).
      await darkLibrary.createMasterDarkEntryForTest(db);
      await flatDao.addEntry(
        filePath: '/cal/master_flat_L.fits',
        filter: 'L',
        gain: 100,
        offset: 10,
        binX: 1,
        binY: 1,
        temperature: -10.0,
      );

      final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];
      await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults.copyWith(drizzle: true),
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );

      // The drizzle call carried a calibration block, and it is byte-identical to
      // the one the standard integrate path applied — so the drizzled master that
      // gets swapped in as canonical is NOT uncalibrated.
      final integrateCal =
          seam.integrateCalls.single['calibration'] as Map<String, dynamic>;
      final drizzleCal =
          seam.drizzleCalls.single['calibration'] as Map<String, dynamic>?;
      expect(
        drizzleCal,
        isNotNull,
        reason: 'drizzle must receive the resolved calibration block',
      );
      expect(drizzleCal!['dark'], '/cal/master_dark.fits');
      expect(drizzleCal['flat'], '/cal/master_flat_L.fits');
      expect(
        drizzleCal,
        equals(integrateCal),
        reason: 'drizzle calibration must match the integrate calibration',
      );
    },
  );

  test(
    'Bayer drizzle sets the bayer flag and yields a 3-channel master',
    () async {
      scriptMetricsWithTransforms();
      final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];

      final outcomes = await service.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults.copyWith(
          drizzle: true,
          bayerDrizzle: true,
        ),
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );

      expect(seam.drizzleCalls.single['bayer'], isTrue);
      final master = await mastersDao.getById(outcomes.single.masterId);
      expect(master!.channels, 3);
    },
  );

  test('drizzle is fail-soft when no accepted sub carries a transform', () async {
    // Default builder: accepted records but no transform field.
    final subs = [await insertSub(path: '/l/a.fits', filter: 'L')];

    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults.copyWith(drizzle: true),
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );

    // No drizzle call fired (nothing to deposit); the standard master survives.
    expect(seam.drizzleCalls, isEmpty);
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master!.masterFitsPath, '/out/master.fits');
  });

  test(
    'an injected plate-solver persists the master WCS (CD-matrix columns)',
    () async {
      final calls = <Map<String, dynamic>>[];
      final solvingService = PostSessionIntegrationService(
        mastersDao: mastersDao,
        calibrationLibrary: calibrationLibrary,
        seam: seam,
        plateSolver:
            ({
              required String imagePath,
              required int imageWidth,
              required int imageHeight,
              double? hintRaHours,
              double? hintDecDegrees,
            }) async {
              calls.add(<String, dynamic>{
                'imagePath': imagePath,
                'imageWidth': imageWidth,
                'imageHeight': imageHeight,
                'hintRaHours': hintRaHours,
                'hintDecDegrees': hintDecDegrees,
              });
              return const MasterWcsSolution(
                crval1: 202.4696,
                crval2: 47.1952,
                crpix1: 50.0,
                crpix2: 40.0,
                cd1_1: -0.000352,
                cd1_2: 0.0000061,
                cd2_1: 0.0000061,
                cd2_2: 0.000352,
              );
            },
      );

      final subs = [await insertSub(path: '/lights/a.fits', filter: 'L')];
      final outcomes = await solvingService.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults,
        targetName: 'M51',
        hintRaHours: 13.498,
        hintDecDegrees: 47.195,
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );

      // The solver was handed the finished master FITS, its dims, and the hint.
      expect(calls, hasLength(1));
      expect(calls.single['imagePath'], '/out/master.fits');
      expect(calls.single['imageWidth'], 100); // fake seam echoes 100x80.
      expect(calls.single['imageHeight'], 80);
      expect(calls.single['hintRaHours'], 13.498);
      expect(calls.single['hintDecDegrees'], 47.195);

      // The eight CD-matrix scalars round-trip onto the row.
      final master = await mastersDao.getById(outcomes.single.masterId);
      expect(master, isNotNull);
      expect(master!.hasWcs, isTrue);
      expect(master.wcsCrval1, closeTo(202.4696, 1e-9));
      expect(master.wcsCrval2, closeTo(47.1952, 1e-9));
      expect(master.wcsCrpix1, closeTo(50.0, 1e-9));
      expect(master.wcsCrpix2, closeTo(40.0, 1e-9));
      expect(master.wcsCd1_1, closeTo(-0.000352, 1e-12));
      expect(master.wcsCd2_2, closeTo(0.000352, 1e-12));
    },
  );

  test('a null-returning solver leaves WCS unpersisted (fail-soft)', () async {
    final solvingService = PostSessionIntegrationService(
      mastersDao: mastersDao,
      calibrationLibrary: calibrationLibrary,
      seam: seam,
      // No solver installed / solve failed -> closure returns null.
      plateSolver:
          ({
            required String imagePath,
            required int imageWidth,
            required int imageHeight,
            double? hintRaHours,
            double? hintDecDegrees,
          }) async => null,
    );

    final subs = [await insertSub(path: '/lights/a.fits', filter: 'L')];
    final outcomes = await solvingService.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults,
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );

    // The master persisted fine; WCS stays null so annotation/colour-cal skip.
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master, isNotNull);
    expect(master!.hasWcs, isFalse);
    expect(master.wcsCrval1, isNull);
  });

  test('no injected solver is a clean no-op (WCS stays null)', () async {
    // `service` (the default harness) is built WITHOUT a plateSolver.
    final subs = [await insertSub(path: '/lights/a.fits', filter: 'L')];
    final outcomes = await service.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults,
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master, isNotNull);
    expect(master!.hasWcs, isFalse);
  });

  // Colour calibration (wired via MasterColorCalibrator)

  /// A plate-solver returning a fixed CD-matrix WCS so the colour-calibration
  /// gate has a master to project against.
  MasterPlateSolver fixedSolver() =>
      ({
        required String imagePath,
        required int imageWidth,
        required int imageHeight,
        double? hintRaHours,
        double? hintDecDegrees,
      }) async => const MasterWcsSolution(
        crval1: 202.4696,
        crval2: 47.1952,
        crpix1: 50.0,
        crpix2: 40.0,
        cd1_1: -0.000352,
        cd1_2: 0.0000061,
        cd2_1: 0.0000061,
        cd2_2: 0.000352,
      );

  test('colorCalibrate gate invokes the injected calibrator with the solved WCS '
      'and persists color_calibrated_path', () async {
    final calls = <Map<String, dynamic>>[];
    final calibratingService = PostSessionIntegrationService(
      mastersDao: mastersDao,
      calibrationLibrary: calibrationLibrary,
      seam: seam,
      plateSolver: fixedSolver(),
      colorCalibrator:
          ({
            required String masterFits,
            required String outputFits,
            required WcsOverlay wcs,
            required int channels,
          }) async {
            calls.add(<String, dynamic>{
              'masterFits': masterFits,
              'outputFits': outputFits,
              'channels': channels,
              // The overlay must carry the solved reference, derived from the CD
              // matrix (RA cdelt negative, |cd| magnitude).
              'crval1': wcs.crval1,
              'crval2': wcs.crval2,
              'cdelt1': wcs.cdelt1,
            });
            return outputFits;
          },
    );

    final subs = [await insertSub(path: '/lights/a.fits', filter: 'L')];
    final outcomes = await calibratingService.integrate(
      subs: subs,
      settings: IntegrationSettings.defaults.copyWith(colorCalibrate: true),
      targetName: 'M51',
      outputFitsPathBuilder: (_) => '/out/master.fits',
    );

    // The calibrator was invoked once against the master FITS, with the
    // suffixed output path, the fake seam's channel count, and a WCS overlay
    // reconstructed from the solved CD matrix.
    expect(calls, hasLength(1));
    final c = calls.single;
    expect(c['masterFits'], '/out/master.fits');
    expect(c['outputFits'], '/out/master_color.fits');
    expect(c['channels'], 1);
    expect(c['crval1'], closeTo(202.4696, 1e-9));
    expect(c['crval2'], closeTo(47.1952, 1e-9));
    expect(c['cdelt1'] as double, lessThan(0)); // RA cdelt is negative.

    // The calibrated FITS path landed on the v42 color_calibrated_path column.
    final master = await mastersDao.getById(outcomes.single.masterId);
    expect(master!.colorCalibratedPath, '/out/master_color.fits');
  });

  test(
    'colorCalibrate gate skips (persists nothing) when no WCS is solved',
    () async {
      var called = false;
      final calibratingService = PostSessionIntegrationService(
        mastersDao: mastersDao,
        calibrationLibrary: calibrationLibrary,
        seam: seam,
        // No plate-solver -> no WCS -> the colour gate has nothing to project.
        colorCalibrator:
            ({
              required String masterFits,
              required String outputFits,
              required WcsOverlay wcs,
              required int channels,
            }) async {
              called = true;
              return outputFits;
            },
      );

      final subs = [await insertSub(path: '/lights/a.fits', filter: 'L')];
      final outcomes = await calibratingService.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults.copyWith(colorCalibrate: true),
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );

      expect(called, isFalse, reason: 'no WCS -> calibrator never called');
      final master = await mastersDao.getById(outcomes.single.masterId);
      expect(master!.colorCalibratedPath, isNull);
    },
  );

  test(
    'colorCalibrate gate persists nothing when the calibrator skips (null)',
    () async {
      final calibratingService = PostSessionIntegrationService(
        mastersDao: mastersDao,
        calibrationLibrary: calibrationLibrary,
        seam: seam,
        plateSolver: fixedSolver(),
        // The field cross-matched too few catalog stars -> skipped (null).
        colorCalibrator:
            ({
              required String masterFits,
              required String outputFits,
              required WcsOverlay wcs,
              required int channels,
            }) async => null,
      );

      final subs = [await insertSub(path: '/lights/a.fits', filter: 'L')];
      final outcomes = await calibratingService.integrate(
        subs: subs,
        settings: IntegrationSettings.defaults.copyWith(colorCalibrate: true),
        outputFitsPathBuilder: (_) => '/out/master.fits',
      );

      // A skipped calibration leaves the column null (no phantom path persisted).
      final master = await mastersDao.getById(outcomes.single.masterId);
      expect(master!.colorCalibratedPath, isNull);
      // But the master + its WCS are unaffected.
      expect(master.hasWcs, isTrue);
    },
  );
}

/// Test-only helper to seed a matching master-dark library entry.
extension on DarkLibraryService {
  Future<void> createMasterDarkEntryForTest(SkotiqDatabase db) async {
    await DarkLibraryDao(db).addEntry(
      DarkLibraryCompanion.insert(
        filePath: '/cal/master_dark.fits',
        exposureTime: 120.0,
        frameType: const Value('dark'),
        temperature: const Value(-10.0),
        gain: const Value(100),
        offset: const Value(10),
        binX: const Value(1),
        binY: const Value(1),
        masterDarkPath: const Value('/cal/master_dark.fits'),
        masterFrameCount: const Value(20),
      ),
    );
  }
}

class _RecordingReporter implements PassReporter {
  final List<(String, String, Map<String, dynamic>)> reports = [];

  @override
  void report(String runId, String kind, [Map<String, dynamic>? detail]) =>
      reports.add((runId, kind, detail ?? const <String, dynamic>{}));

  @override
  void reportForSession(
    int sessionId,
    String kind, [
    Map<String, dynamic>? detail,
  ]) => reports.add((
    'session-$sessionId',
    kind,
    detail ?? const <String, dynamic>{},
  ));

  @override
  String? runningForSession(int sessionId) => null;

  @override
  Future<String?> previewDir(String runId) async => '/previews/$runId';
}
