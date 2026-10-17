// End-to-end guard for the Mosaic M2 [MosaicProjectService] — the durable spine
// that plans a mosaic into per-panel rows, integrates each panel's subs into a
// per-panel master, and stitches those masters into one mosaic master.
//
// Everything runs on an in-memory DB with the REAL v45 DAOs + the real
// [PostSessionIntegrationService], and a Fake [PostSessionSeam] standing in for
// the native FFI (integrate echoes a master per filter group; stitchMosaic
// records its request and echoes a canvas). This pins the three contracts the
// service owns:
//
//   * createProject persists the project + the right per-panel centers + count,
//     reusing MosaicService.generatePanels for the geometry (NOT re-derived).
//   * integratePanels links each panel's per-panel master and is fail-soft
//     per panel (a panel with no subs is left pending, the rest still link).
//   * stitchProject calls stitchMosaic with ALL panel master paths, persists the
//     stitched master as a new integrated_masters row, and links it onto the
//     project's output_master_id (status -> complete).

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:skotiq_core/src/database/daos/calibration_tags_dao.dart';
import 'package:skotiq_core/src/database/daos/flat_library_dao.dart';
import 'package:skotiq_core/src/database/daos/images_dao.dart';
import 'package:skotiq_core/src/database/daos/integrated_masters_dao.dart';
import 'package:skotiq_core/src/database/daos/mosaic_panels_dao.dart';
import 'package:skotiq_core/src/database/daos/mosaic_projects_dao.dart';
import 'package:skotiq_core/src/database/daos/targets_dao.dart';
import 'package:skotiq_core/src/database/database.dart';
import 'package:skotiq_core/src/models/imaging/integration_settings.dart';
import 'package:skotiq_core/src/models/imaging/mosaic_project.dart';
import 'package:skotiq_core/src/models/imaging/mosaic_stitch_result.dart';
import 'package:skotiq_core/src/services/calibration_library_service.dart';
import 'package:skotiq_core/src/services/mosaic_project_service.dart';
import 'package:skotiq_core/src/services/post_session_integration_service.dart';
import 'package:skotiq_core/src/services/post_session_seam.dart';

/// A scriptable [PostSessionSeam]: `integrateSession` echoes one accepted record
/// per light path (and stamps the master's solved WCS via the injected plate
/// solver path is N/A here — WCS is set straight onto the master row in the
/// stitch test), and `stitchMosaic` records its request + echoes a canvas. Only
/// the members the orchestration exercises are implemented.
class _FakeSeam implements PostSessionSeam {
  final List<Map<String, dynamic>> integrateCalls = [];
  final List<Map<String, dynamic>> stitchCalls = [];

  /// Optional scripted stitch result; when null the fake echoes the request.
  MosaicStitchResult? stitchResult;

  /// When true, `stitchMosaic` throws (after recording the call) — used to
  /// drive the stuck-status rollback path.
  bool throwOnStitch = false;

  /// When true, `integrateSession` actually WRITES a real master FITS file at
  /// the requested `masterFitsPath` — exactly as the native integrator does
  /// (`post_session.rs:748`). Off by default so existing tests that hand
  /// unwritable absolute paths (e.g. `/out/...`) keep echoing only. The
  /// re-integration guard tests turn this on (with a real temp dir) so they
  /// exercise the production on-disk artifact lifecycle, not a path echo.
  bool writeMasterFiles = false;

  @override
  Future<IntegrateSessionResult> integrateSession(
    Map<String, dynamic> args,
  ) async {
    integrateCalls.add(args);
    final lights = (args['lightPaths'] as List).cast<String>();
    final output = args['output'] as Map<String, dynamic>;
    if (writeMasterFiles) {
      // Production-faithful: the native integrator writes the linear FITS
      // master to `masterFitsPath`. Mirror that so a re-integration's
      // supersession is tested against a REAL file on the durable deterministic
      // path, not an echoed string.
      final masterPath = output['masterFitsPath'] as String;
      final file = File(masterPath);
      await file.create(recursive: true);
      await file.writeAsString('master-pixels for ${lights.join(",")}');
    }
    return IntegrateSessionResult(
      masterFitsPath: output['masterFitsPath'] as String,
      previewPath: output['previewPngPath'] as String?,
      rejectionMapPath: output['rejectionMapPath'] as String?,
      framesIntegrated: lights.length,
      framesRejected: 0,
      totalIntegrationSec: 120.0 * lights.length,
      rmsResidual: 0.4,
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
  Future<MosaicStitchResult> stitchMosaic(Map<String, dynamic> args) async {
    stitchCalls.add(args);
    if (throwOnStitch) {
      throw StateError('native stitch failed (scripted)');
    }
    if (stitchResult != null) return stitchResult!;
    final output = (args['output'] as Map).cast<String, dynamic>();
    final panels = (args['panels'] as List).length;
    return MosaicStitchResult(
      outputPath: output['mosaicFitsPath'] as String,
      coveragePath: output['coverageFitsPath'] as String?,
      previewPath: output['previewPngPath'] as String?,
      outWidth: 100 * panels,
      outHeight: 80,
      overlapPairs: panels - 1,
      meanPanelGain: 1.0,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not faked');
}

void main() {
  late SkotiqDatabase db;
  late ImagesDao imagesDao;
  late IntegratedMastersDao mastersDao;
  late MosaicProjectsDao projectsDao;
  late MosaicPanelsDao panelsDao;
  late TargetsDao targetsDao;
  late _FakeSeam seam;
  late PostSessionIntegrationService integration;
  late MosaicProjectService service;

  setUp(() {
    db = SkotiqDatabase.forTesting(NativeDatabase.memory());
    imagesDao = db.imagesDao;
    mastersDao = IntegratedMastersDao(db);
    projectsDao = MosaicProjectsDao(db);
    panelsDao = MosaicPanelsDao(db);
    targetsDao = TargetsDao(db);
    seam = _FakeSeam();
    integration = PostSessionIntegrationService(
      mastersDao: mastersDao,
      calibrationLibrary: CalibrationLibraryService(
        db: db,

        flatLibraryDao: FlatLibraryDao(db),

        tagsDao: CalibrationTagsDao(db),
      ),
      seam: seam,
    );
    service = MosaicProjectService(
      db: db,
      projectsDao: projectsDao,
      panelsDao: panelsDao,
      targetsDao: targetsDao,
      imagesDao: imagesDao,
      mastersDao: mastersDao,
      integrationService: integration,
      seam: seam,
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> seedTarget(String name) {
    return db.customInsert(
      'INSERT INTO targets (name, ra, dec) VALUES (?, ?, ?)',
      variables: [
        Variable<String>(name),
        const Variable<double>(0.7),
        const Variable<double>(41.0),
      ],
    );
  }

  Future<void> seedSub({
    required int targetId,
    required String path,
    bool accepted = true,
    String filter = 'L',
  }) async {
    await db
        .into(db.capturedImages)
        .insert(
          CapturedImagesCompanion.insert(
            filePath: path,
            fileName: path.split('/').last,
            frameType: const Value('light'),
            exposureDuration: 120.0,
            capturedAt: DateTime(2026, 6, 7, 22),
            targetId: Value(targetId),
            gain: const Value(100),
            offset: const Value(10),
            binX: const Value(1),
            binY: const Value(1),
            filter: Value(filter),
            sensorTemp: const Value(-10.0),
            hfr: const Value(2.0),
            qualityScore: const Value(80.0),
            isAccepted: Value(accepted),
          ),
        );
  }

  group('createProject', () {
    test('persists the project + per-panel rows with generated centers', () async {
      final regionTarget = await seedTarget('Andromeda');
      final projectId = await service.createProject(
        name: 'M31 2x3',
        rows: 2,
        cols: 3,
        centerRa: 0.7,
        centerDec: 41.0,
        targetId: regionTarget,
        overlapPct: 20.0,
        positionAngleDeg: 0.0,
        // 1 deg x 0.75 deg rig FOV.
        fovWidthDeg: 1.0,
        fovHeightDeg: 0.75,
      );

      final project = await projectsDao.getById(projectId);
      expect(project, isNotNull);
      expect(project!.name, 'M31 2x3');
      expect(project.rows, 2);
      expect(project.cols, 3);
      expect(project.totalPanels, 6);
      expect(project.overlapPct, closeTo(20.0, 1e-9));
      expect(project.targetId, regionTarget);
      expect(project.status, MosaicProjectStatus.planning);

      final panels = await panelsDao.getForProject(projectId);
      expect(panels, hasLength(6));
      // 0-based, row-major, contiguous.
      expect(panels.map((p) => p.panelIndex).toList(), [0, 1, 2, 3, 4, 5]);
      // Each panel got its OWN distinct capture target (NOT the region target),
      // so a panel's subs isolate to that panel for per-panel integration.
      final panelTargets = panels.map((p) => p.targetId).toList();
      expect(panelTargets.every((t) => t != null), isTrue);
      expect(
        panelTargets.toSet(),
        hasLength(6),
        reason: 'every panel must resolve to a DISTINCT capture target',
      );
      expect(
        panelTargets.contains(regionTarget),
        isFalse,
        reason: 'panels must not reuse the project-region target',
      );
      // The per-panel target rows are centered on the panel (not the region).
      final byIndexEarly = {for (final p in panels) p.panelIndex: p};
      final p1Target = await targetsDao.getTargetById(
        byIndexEarly[1]!.targetId!,
      );
      expect(p1Target, isNotNull);
      expect(p1Target!.ra, closeTo(byIndexEarly[1]!.centerRa, 1e-6));
      expect(p1Target.dec, closeTo(byIndexEarly[1]!.centerDec, 1e-6));
      // All pending, zero captured at creation.
      expect(
        panels.every((p) => p.status == MosaicPanelStatus.pending),
        isTrue,
      );
      expect(panels.every((p) => p.capturedCount == 0), isTrue);

      // The centers are the EXISTING geometry's output (cos(dec) RA compression
      // spreads RA more than the bare FOV at dec=41). The grid is symmetric
      // about the project center, so the row-0 cols straddle 0.7h and the dec
      // band splits +/- around 41.0.
      final byIndex = {for (final p in panels) p.panelIndex: p};
      // Middle column of each row sits on the center RA.
      expect(byIndex[1]!.centerRa, closeTo(0.7, 1e-6));
      expect(byIndex[4]!.centerRa, closeTo(0.7, 1e-6));
      // Two rows split symmetrically in dec about 41.0.
      expect(
        byIndex[1]!.centerDec + byIndex[4]!.centerDec,
        closeTo(2 * 41.0, 1e-6),
      );
      // Columns within a row are ordered low->high RA and distinct.
      expect(byIndex[0]!.centerRa, lessThan(byIndex[1]!.centerRa));
      expect(byIndex[1]!.centerRa, lessThan(byIndex[2]!.centerRa));
    });

    test(
      'derives panel arcmin from explicit dims and rejects a bad grid',
      () async {
        final id = await service.createProject(
          name: 'tiny',
          rows: 1,
          cols: 2,
          centerRa: 12.0,
          centerDec: 0.0,
          panelWidthArcmin: 30.0,
          panelHeightArcmin: 20.0,
        );
        expect(await panelsDao.getForProject(id), hasLength(2));

        await expectLater(
          service.createProject(
            name: 'bad',
            rows: 0,
            cols: 2,
            centerRa: 1,
            centerDec: 1,
            panelWidthArcmin: 30,
            panelHeightArcmin: 20,
          ),
          throwsArgumentError,
        );
        await expectLater(
          service.createProject(
            name: 'no-dims',
            rows: 1,
            cols: 2,
            centerRa: 1,
            centerDec: 1,
          ),
          throwsArgumentError,
        );
      },
    );
  });

  group('integratePanels', () {
    test('links a per-panel master for each panel that has accepted subs', () async {
      // Two panel targets, each with their own subs.
      final p0Target = await seedTarget('Mosaic Panel 1');
      final p1Target = await seedTarget('Mosaic Panel 2');
      await seedSub(targetId: p0Target, path: '/p0/a.fits');
      await seedSub(targetId: p0Target, path: '/p0/b.fits');
      await seedSub(targetId: p1Target, path: '/p1/a.fits');
      // A rejected sub on panel 1 must not be folded.
      await seedSub(
        targetId: p1Target,
        path: '/p1/reject.fits',
        accepted: false,
      );

      final projectId = await service.createProject(
        name: 'Pair',
        rows: 1,
        cols: 2,
        centerRa: 0.7,
        centerDec: 41.0,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        // Give each panel its own capture target.
        panelTargetId: (i) => i == 0 ? p0Target : p1Target,
      );

      final outcomes = await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (panel) => '/out/panel_${panel.panelIndex}.fits',
      );

      expect(outcomes, hasLength(2));
      expect(outcomes.every((o) => o.integrated), isTrue);
      // Panel 0 folded its two accepted subs; panel 1 folded one (reject skipped).
      expect(outcomes[0].subCount, 2);
      expect(outcomes[1].subCount, 1);

      // Two integrate calls (one per panel), each with that panel's subs + the
      // panel's own output path.
      expect(seam.integrateCalls, hasLength(2));
      expect(
        (seam.integrateCalls[0]['lightPaths'] as List).cast<String>(),
        containsAll(['/p0/a.fits', '/p0/b.fits']),
      );
      expect((seam.integrateCalls[1]['lightPaths'] as List).cast<String>(), [
        '/p1/a.fits',
      ]);

      // Each panel row now carries its per-panel master + integrated status.
      final panels = await panelsDao.getForProject(projectId);
      expect(panels.every((p) => p.integratedMasterId != null), isTrue);
      expect(
        panels.every((p) => p.status == MosaicPanelStatus.integrated),
        isTrue,
      );
      // The master rows exist and point at the right FITS. Subs are filter 'L',
      // so the per-filter master gets the bucket-suffixed path (the bug was
      // every per-filter master sharing the bare base path and clobbering each
      // other on disk).
      final m0 = await mastersDao.getById(panels[0].integratedMasterId!);
      expect(m0!.masterFitsPath, '/out/panel_0_L.fits');

      // The project moved into the integrating phase.
      final project = await projectsDao.getById(projectId);
      expect(project!.status, MosaicProjectStatus.integrating);
    });

    test('is fail-soft per panel: a panel with no subs stays pending', () async {
      final p0Target = await seedTarget('Has Subs');
      final p1Target = await seedTarget('No Subs');
      await seedSub(targetId: p0Target, path: '/p0/a.fits');

      final projectId = await service.createProject(
        name: 'Half',
        rows: 1,
        cols: 2,
        centerRa: 0.7,
        centerDec: 41.0,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (i) => i == 0 ? p0Target : p1Target,
      );

      final outcomes = await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (panel) => '/out/panel_${panel.panelIndex}.fits',
      );

      // Panel 0 integrated; panel 1 (no subs) is left pending, not failed, and
      // did not abort the run.
      expect(outcomes[0].integrated, isTrue);
      expect(outcomes[0].status, MosaicPanelStatus.integrated);
      expect(outcomes[1].integrated, isFalse);
      expect(outcomes[1].status, MosaicPanelStatus.pending);
      // Only one integrate call was issued (the empty panel was skipped).
      expect(seam.integrateCalls, hasLength(1));

      final panels = await panelsDao.getForProject(projectId);
      expect(panels[0].integratedMasterId, isNotNull);
      expect(panels[1].integratedMasterId, isNull);
    });

    test(
      'a multi-filter panel writes one distinct master FITS per filter '
      '(no on-disk clobber) and links luminance as the representative',
      () async {
        // One panel captured in L + R + G + B. The bug: every per-filter master
        // was handed the SAME base path, so each filter overwrote the previous
        // filter's FITS/PNG/rejmap on disk, and the panel linked outcomes.first
        // (iteration order), not a meaningful representative.
        final panelTarget = await seedTarget('LRGB Panel');
        // Give R two subs so it is the highest-frame-count group — proving the
        // representative pick is NOT "most frames" when luminance is present.
        await seedSub(
          targetId: panelTarget,
          path: '/lrgb/r1.fits',
          filter: 'R',
        );
        await seedSub(
          targetId: panelTarget,
          path: '/lrgb/r2.fits',
          filter: 'R',
        );
        await seedSub(
          targetId: panelTarget,
          path: '/lrgb/g1.fits',
          filter: 'G',
        );
        await seedSub(
          targetId: panelTarget,
          path: '/lrgb/b1.fits',
          filter: 'B',
        );
        await seedSub(
          targetId: panelTarget,
          path: '/lrgb/l1.fits',
          filter: 'L',
        );

        final projectId = await service.createProject(
          name: 'LRGB',
          rows: 1,
          cols: 1,
          centerRa: 0.7,
          centerDec: 41.0,
          panelWidthArcmin: 30,
          panelHeightArcmin: 20,
          panelTargetId: (_) => panelTarget,
        );

        final outcomes = await service.integratePanels(
          projectId,
          settings: IntegrationSettings.defaults,
          outputFitsPathBuilder: (panel) =>
              '/out/panel_${panel.panelIndex}.fits',
        );

        // One panel outcome; it folded ALL five accepted subs across filters.
        expect(outcomes, hasLength(1));
        expect(outcomes.single.subCount, 5);
        expect(outcomes.single.status, MosaicPanelStatus.integrated);

        // Four integrate calls (one per filter), each writing a DISTINCT master
        // FITS path so no filter clobbers another's pixels on disk. The
        // luminance group keeps deriving its preview/rejmap from its own base.
        expect(seam.integrateCalls, hasLength(4));
        final masterPaths = seam.integrateCalls
            .map((c) => (c['output'] as Map)['masterFitsPath'] as String)
            .toList();
        expect(
          masterPaths.toSet(),
          hasLength(4),
          reason: 'each per-filter master must get a distinct FITS path',
        );
        expect(masterPaths.toSet(), {
          '/out/panel_0_R.fits',
          '/out/panel_0_G.fits',
          '/out/panel_0_B.fits',
          '/out/panel_0_L.fits',
        });

        // The persisted master rows are also distinct files (no duplicate rows
        // all pointing at one path), one per filter.
        final allMasters = await mastersDao.getAll();
        final lrgbMasters = allMasters
            .where((m) => m.masterFitsPath?.startsWith('/out/panel_0') ?? false)
            .toList();
        expect(lrgbMasters, hasLength(4));
        expect(
          lrgbMasters.map((m) => m.masterFitsPath).toSet(),
          hasLength(4),
          reason:
              'four filters must yield four on-disk FITS, not one clobbered',
        );

        // The panel links the LUMINANCE master as its representative — even
        // though R has the most frames and L was not the first filter group.
        final panels = await panelsDao.getForProject(projectId);
        final linked = await mastersDao.getById(
          panels.single.integratedMasterId!,
        );
        expect(linked!.masterFitsPath, '/out/panel_0_L.fits');
        expect(linked.filter, 'L');
      },
    );

    test('a multi-filter panel with no luminance links the highest-frame-count '
        'master as the representative', () async {
      // R(3) + G(1) + B(1), no L. The representative must be the deepest group
      // (R), not whichever filter happened to be the first sub captured.
      final panelTarget = await seedTarget('RGB Panel');
      await seedSub(targetId: panelTarget, path: '/rgb/g1.fits', filter: 'G');
      await seedSub(targetId: panelTarget, path: '/rgb/b1.fits', filter: 'B');
      await seedSub(targetId: panelTarget, path: '/rgb/r1.fits', filter: 'R');
      await seedSub(targetId: panelTarget, path: '/rgb/r2.fits', filter: 'R');
      await seedSub(targetId: panelTarget, path: '/rgb/r3.fits', filter: 'R');

      final projectId = await service.createProject(
        name: 'RGB',
        rows: 1,
        cols: 1,
        centerRa: 0.7,
        centerDec: 41.0,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (_) => panelTarget,
      );

      await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (panel) => '/out/panel_${panel.panelIndex}.fits',
      );

      final panels = await panelsDao.getForProject(projectId);
      final linked = await mastersDao.getById(
        panels.single.integratedMasterId!,
      );
      // R has 3 frames vs 1 each for G/B, so R is the representative.
      expect(linked!.filter, 'R');
      expect(linked.masterFitsPath, '/out/panel_0_R.fits');
    });

    test(
      'an unfiltered panel keeps the bare base FITS path (no bucket suffix)',
      () async {
        // Subs captured WITHOUT a filter recorded fall in the noFilterBucket and
        // must keep the bare base path — there is nothing to disambiguate, and a
        // `_(none)` suffix would be ugly noise. (A NAMED single filter like 'L'
        // is still suffixed; that is covered by the LRGB/RGB tests above.)
        final panelTarget = await seedTarget('Mono Panel');
        await seedSub(targetId: panelTarget, path: '/mono/a.fits', filter: '');
        await seedSub(targetId: panelTarget, path: '/mono/b.fits', filter: '');

        final projectId = await service.createProject(
          name: 'Mono',
          rows: 1,
          cols: 1,
          centerRa: 0.7,
          centerDec: 41.0,
          panelWidthArcmin: 30,
          panelHeightArcmin: 20,
          panelTargetId: (_) => panelTarget,
        );

        await service.integratePanels(
          projectId,
          settings: IntegrationSettings.defaults,
          outputFitsPathBuilder: (panel) =>
              '/out/panel_${panel.panelIndex}.fits',
        );

        expect(seam.integrateCalls, hasLength(1));
        expect(
          (seam.integrateCalls.single['output'] as Map)['masterFitsPath'],
          '/out/panel_0.fits',
        );
        final panels = await panelsDao.getForProject(projectId);
        final linked = await mastersDao.getById(
          panels.single.integratedMasterId!,
        );
        expect(linked!.masterFitsPath, '/out/panel_0.fits');
      },
    );
  });

  group('stitchProject', () {
    // The stitch path PROBES that each panel master FITS exists on disk before
    // handing it to the native stitcher, so these tests integrate against a REAL
    // temp dir with the production-faithful seam (it writes the master FITS at
    // `masterFitsPath`), exactly as the native integrator does — otherwise every
    // panel is correctly skipped for a missing file.
    late Directory stitchTmp;
    late String outRoot;
    setUp(() async {
      seam.writeMasterFiles = true;
      stitchTmp = await Directory.systemTemp.createTemp(
        'skotiq_mosaic_stitch_',
      );
      outRoot = '${stitchTmp.path}/out';
    });
    tearDown(() async {
      if (await stitchTmp.exists()) await stitchTmp.delete(recursive: true);
    });

    /// Build a 1x2 project, integrate both panels, stamp each panel master with
    /// a (plate-solved-equivalent) WCS so they pass the stitch WCS gate, then
    /// return the project id.
    Future<int> integratedPair() async {
      final p0Target = await seedTarget('Stitch Panel 1');
      final p1Target = await seedTarget('Stitch Panel 2');
      await seedSub(targetId: p0Target, path: '/p0/a.fits');
      await seedSub(targetId: p1Target, path: '/p1/a.fits');

      final projectId = await service.createProject(
        name: 'Veil 1x2',
        rows: 1,
        cols: 2,
        centerRa: 20.85,
        centerDec: 30.7,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (i) => i == 0 ? p0Target : p1Target,
      );
      await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (panel) =>
            '$outRoot/panel_${panel.panelIndex}.fits',
      );
      // Every per-panel master carries its own plate-solved WCS in production;
      // stamp it so both panels pass the stitch WCS gate.
      final panels = await panelsDao.getForProject(projectId);
      for (final panel in panels) {
        await mastersDao.updateWcs(
          panel.integratedMasterId!,
          crval1: 312.0,
          crval2: 30.7,
          crpix1: 50,
          crpix2: 40,
          cd1_1: -0.0011,
          cd1_2: 0.0,
          cd2_1: 0.0,
          cd2_2: 0.0011,
        );
      }
      return projectId;
    }

    test(
      'stitches all panel masters and persists + links the mosaic master',
      () async {
        final projectId = await integratedPair();

        final outcome = await service.stitchProject(
          projectId,
          outputDirectory: '/projects/veil',
          stitchConfig: const {'normalize': true, 'blend': 'feather'},
        );

        // The seam received ONE stitch call carrying BOTH panel FITS paths.
        expect(seam.stitchCalls, hasLength(1));
        final call = seam.stitchCalls.single;
        final panelPaths = (call['panels'] as List)
            .map((p) => (p as Map)['fitsPath'] as String)
            .toList();
        // Panels were captured in 'L', so their representative masters carry the
        // bucket-suffixed FITS paths.
        expect(
          panelPaths,
          containsAll(['$outRoot/panel_0_L.fits', '$outRoot/panel_1_L.fits']),
        );
        expect(call['config'], {'normalize': true, 'blend': 'feather'});
        // Output paths land under the project folder, slugged from the name.
        final output = call['output'] as Map;
        expect(output['mosaicFitsPath'], '/projects/veil/Veil_1x2_mosaic.fits');
        expect(
          output['coverageFitsPath'],
          '/projects/veil/Veil_1x2_mosaic_coverage.fits',
        );
        expect(output['previewPngPath'], '/projects/veil/Veil_1x2_mosaic.png');

        // The stitched master is a NEW integrated_masters row, finalized/batch.
        expect(outcome.panelCount, 2);
        final master = await mastersDao.getById(outcome.outputMasterId);
        expect(master, isNotNull);
        expect(master!.name, 'Veil 1x2 · Mosaic');
        expect(master.masterFitsPath, '/projects/veil/Veil_1x2_mosaic.fits');
        expect(master.previewPngPath, '/projects/veil/Veil_1x2_mosaic.png');
        // Canvas geometry came from the stitch result (100 * 2 panels wide).
        expect(master.width, 200);
        expect(master.height, 80);
        final stats = jsonDecode(master.statsJson) as Map<String, dynamic>;
        expect(stats['panelCount'], 2);
        expect(stats['overlapPairs'], 1);

        // The project is complete and linked to the mosaic master.
        final project = await projectsDao.getById(projectId);
        expect(project!.status, MosaicProjectStatus.complete);
        expect(project.outputMasterId, outcome.outputMasterId);
        expect(project.isComplete, isTrue);
      },
    );

    test(
      'passes each panel master\'s persisted WCS into the stitch request',
      () async {
        // Build the pair WITHOUT the blanket-WCS stamp so we control each panel's
        // WCS independently.
        final p0Target = await seedTarget('WCS Panel 1');
        final p1Target = await seedTarget('WCS Panel 2');
        await seedSub(targetId: p0Target, path: '/p0/a.fits');
        await seedSub(targetId: p1Target, path: '/p1/a.fits');
        final projectId = await service.createProject(
          name: 'Veil 1x2',
          rows: 1,
          cols: 2,
          centerRa: 20.85,
          centerDec: 30.7,
          panelWidthArcmin: 30,
          panelHeightArcmin: 20,
          panelTargetId: (i) => i == 0 ? p0Target : p1Target,
        );
        await service.integratePanels(
          projectId,
          settings: IntegrationSettings.defaults,
          outputFitsPathBuilder: (panel) =>
              '$outRoot/panel_${panel.panelIndex}.fits',
        );

        // Stamp a persisted WCS onto panel 0's master (the v44 columns the
        // per-panel integration plate-solved). Leave panel 1 WITHOUT a persisted
        // WCS — its FITS header carries the WCS, so the WCS gate admits it via the
        // header probe and the native side parses the header itself.
        final panels = await panelsDao.getForProject(projectId);
        await mastersDao.updateWcs(
          panels[0].integratedMasterId!,
          crval1: 312.0,
          crval2: 30.7,
          crpix1: 50,
          crpix2: 40,
          cd1_1: -0.0011,
          cd1_2: 0.0,
          cd2_1: 0.0,
          cd2_2: 0.0011,
        );

        await service.stitchProject(
          projectId,
          outputDirectory: '$outRoot/veil',
          // Panel 1's FITS header has a WCS even though no CD-matrix is persisted.
          fitsHasWcs: (path) async => path == '$outRoot/panel_1_L.fits',
        );

        final call = seam.stitchCalls.single;
        final p0 = (call['panels'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .firstWhere((p) => p['fitsPath'] == '$outRoot/panel_0_L.fits');
        final p1 = (call['panels'] as List)
            .map((e) => (e as Map).cast<String, dynamic>())
            .firstWhere((p) => p['fitsPath'] == '$outRoot/panel_1_L.fits');
        expect(p0['wcs'], isNotNull);
        expect((p0['wcs'] as Map)['cd1_1'], -0.0011);
        expect((p0['wcs'] as Map)['crval1'], 312.0);
        // No persisted WCS -> no wcs block (native parses the header).
        expect(p1.containsKey('wcs'), isFalse);
      },
    );

    test('requires >= 2 panels with masters else a clear error', () async {
      // Build a project but integrate only one panel (the other has no subs).
      final p0Target = await seedTarget('Only One');
      await seedSub(targetId: p0Target, path: '/p0/a.fits');
      final projectId = await service.createProject(
        name: 'Lonely',
        rows: 1,
        cols: 2,
        centerRa: 1,
        centerDec: 1,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (i) => i == 0 ? p0Target : null,
      );
      await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (panel) => '/out/panel_${panel.panelIndex}.fits',
      );

      await expectLater(
        service.stitchProject(projectId, outputDirectory: '/p'),
        throwsA(isA<StateError>()),
      );
      // No stitch was attempted, and the project was NOT marked complete.
      expect(seam.stitchCalls, isEmpty);
      final project = await projectsDao.getById(projectId);
      expect(project!.status, isNot(MosaicProjectStatus.complete));
      expect(project.outputMasterId, isNull);
    });

    test(
      'skips a panel master with NO WCS instead of aborting the whole mosaic',
      () async {
        // Three panels integrate; one (panel 1) has no persisted WCS and no
        // header WCS. The WCS gate must SKIP it (report it) and stitch the other
        // two — NOT hand the WCS-less panel to the stitcher (which would abort the
        // whole mosaic).
        final t0 = await seedTarget('WCS-skip P1');
        final t1 = await seedTarget('WCS-skip P2');
        final t2 = await seedTarget('WCS-skip P3');
        await seedSub(targetId: t0, path: '/p0/a.fits');
        await seedSub(targetId: t1, path: '/p1/a.fits');
        await seedSub(targetId: t2, path: '/p2/a.fits');
        final projectId = await service.createProject(
          name: 'Trio 1x3',
          rows: 1,
          cols: 3,
          centerRa: 20.85,
          centerDec: 30.7,
          panelWidthArcmin: 30,
          panelHeightArcmin: 20,
          panelTargetId: (i) => [t0, t1, t2][i],
        );
        await service.integratePanels(
          projectId,
          settings: IntegrationSettings.defaults,
          outputFitsPathBuilder: (panel) =>
              '$outRoot/panel_${panel.panelIndex}.fits',
        );
        // Stamp WCS on panels 0 and 2 only; panel 1 stays WCS-less.
        final panels = await panelsDao.getForProject(projectId);
        for (final idx in [0, 2]) {
          await mastersDao.updateWcs(
            panels[idx].integratedMasterId!,
            crval1: 312.0,
            crval2: 30.7,
            crpix1: 50,
            crpix2: 40,
            cd1_1: -0.0011,
            cd1_2: 0.0,
            cd2_1: 0.0,
            cd2_2: 0.0011,
          );
        }

        // No fitsHasWcs probe -> panel 1 cannot prove a header WCS -> skipped.
        // (Its FITS file DOES exist — the seam wrote it — so the skip is the WCS
        // gate, not the new file-existence gate.)
        final outcome = await service.stitchProject(
          projectId,
          outputDirectory: '$outRoot/trio',
        );

        // The stitch ran on the TWO WCS panels; panel 1 was skipped + reported.
        expect(outcome.panelCount, 2);
        expect(outcome.skips, hasLength(1));
        expect(outcome.skips.single.panelIndex, 1);
        expect(outcome.skips.single.reason, contains('WCS'));
        final call = seam.stitchCalls.single;
        final paths = (call['panels'] as List)
            .map((p) => (p as Map)['fitsPath'] as String)
            .toList();
        expect(
          paths,
          containsAll(['$outRoot/panel_0_L.fits', '$outRoot/panel_2_L.fits']),
        );
        expect(
          paths.contains('$outRoot/panel_1_L.fits'),
          isFalse,
          reason: 'the WCS-less panel must NOT be handed to the stitcher',
        );
        // The project still completed (the WCS panels stitched fine).
        final project = await projectsDao.getById(projectId);
        expect(project!.status, MosaicProjectStatus.complete);
      },
    );

    test('skips a panel whose master FITS is MISSING on disk instead of aborting '
        'the whole mosaic', () async {
      // A non-empty FITS path is NOT proof the file is on disk. A master FITS
      // removed by a temp sweep / manual cleanup / a supersession bug degrades
      // to a SKIPPED panel — never a path to a missing file handed to the
      // native stitcher, which aborts the whole mosaic. The seam writes real
      // files; ONE panel's FITS is then deleted to produce the missing-file
      // case.
      seam.writeMasterFiles = true;
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_mosaic_missing_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final t0 = await seedTarget('Missing P0');
      final t1 = await seedTarget('Missing P1');
      final t2 = await seedTarget('Missing P2');
      await seedSub(targetId: t0, path: '/m/p0.fits');
      await seedSub(targetId: t1, path: '/m/p1.fits');
      await seedSub(targetId: t2, path: '/m/p2.fits');
      final projectId = await service.createProject(
        name: 'Missing 1x3',
        rows: 1,
        cols: 3,
        centerRa: 20.85,
        centerDec: 30.7,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (i) => [t0, t1, t2][i],
      );
      await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: (panel) =>
            '${tempDir.path}/panel_${panel.panelIndex}.fits',
      );

      final panels = await panelsDao.getForProject(projectId);
      // Stamp WCS on all three so the WCS gate would pass them — isolating the
      // FILE-EXISTENCE gate as the sole reason panel 1 is skipped.
      for (final idx in [0, 1, 2]) {
        await mastersDao.updateWcs(
          panels[idx].integratedMasterId!,
          crval1: 312.0,
          crval2: 30.7,
          crpix1: 50,
          crpix2: 40,
          cd1_1: -0.0011,
          cd1_2: 0.0,
          cd2_1: 0.0,
          cd2_2: 0.0011,
        );
      }
      // Delete panel 1's master FITS off disk (its DB row + WCS stay live).
      final p1Master = await mastersDao.getById(panels[1].integratedMasterId!);
      final missingPath = p1Master!.masterFitsPath!;
      await File(missingPath).delete();
      expect(await File(missingPath).exists(), isFalse);

      final outcome = await service.stitchProject(
        projectId,
        outputDirectory: tempDir.path,
      );

      // The stitch ran on the TWO present panels; panel 1 was skipped + reported
      // for the missing file — the mosaic was NOT aborted.
      expect(outcome.panelCount, 2);
      expect(outcome.skips, hasLength(1));
      expect(outcome.skips.single.panelIndex, 1);
      expect(outcome.skips.single.reason, contains('missing on disk'));
      final paths = (seam.stitchCalls.single['panels'] as List)
          .map((p) => (p as Map)['fitsPath'] as String)
          .toList();
      expect(
        paths.contains(missingPath),
        isFalse,
        reason: 'the missing-file panel must NOT be handed to the stitcher',
      );
      final project = await projectsDao.getById(projectId);
      expect(project!.status, MosaicProjectStatus.complete);
    });

    test(
      'reverts project status off `stitching` when the native stitch throws',
      () async {
        final projectId = await integratedPair();
        // Make the seam throw on stitch.
        seam.throwOnStitch = true;

        await expectLater(
          service.stitchProject(projectId, outputDirectory: '/p/veil'),
          throwsA(isA<StateError>()),
        );

        // The project must NOT be left pinned in `stitching` — it reverted to
        // `integrating` so the stitch can be retried, never stuck in a dead phase.
        final project = await projectsDao.getById(projectId);
        expect(project!.status, MosaicProjectStatus.integrating);
        expect(project.outputMasterId, isNull);
      },
    );
  });

  group('re-integration idempotency', () {
    test('re-integrating a panel SETs captured_count (not +=), supersedes the '
        'previous master ROW (no orphan), and PRESERVES the freshly-written '
        'master FITS on the durable deterministic path', () async {
      // PRODUCTION-FAITHFUL: the seam actually writes the master FITS at
      // `masterFitsPath` (exactly as native `post_session.rs:748`). The panel's
      // master always lands on the DURABLE DETERMINISTIC path
      // (`<base>/panel_<i>[_<filter>].fits`), IDENTICAL across re-runs.
      //
      // Supersession must be PATH-AWARE: an id-only guard deletes the prior
      // master's `masterFitsPath`, which is the SAME path the new master was
      // just written to, leaving the panel linked to a live DB row whose FITS
      // is gone and aborting the stitch. The invariant is that the new file
      // SURVIVES.
      seam.writeMasterFiles = true;
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_mosaic_reint_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final panelTarget = await seedTarget('Re-int Panel');
      await seedSub(targetId: panelTarget, path: '/reint/a.fits');
      await seedSub(targetId: panelTarget, path: '/reint/b.fits');

      final projectId = await service.createProject(
        name: 'Reint 1x1',
        rows: 1,
        cols: 1,
        centerRa: 0.7,
        centerDec: 41.0,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (_) => panelTarget,
      );

      String panelBase(MosaicProjectPanel panel) =>
          '${tempDir.path}/panel_${panel.panelIndex}.fits';

      // First integration: 2 subs (filter 'L' -> suffixed master file). The
      // seam writes the real FITS to the deterministic path.
      await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: panelBase,
      );
      var panels = await panelsDao.getForProject(projectId);
      final firstMasterId = panels.single.integratedMasterId!;
      expect(panels.single.capturedCount, 2);
      final firstMaster = await mastersDao.getById(firstMasterId);
      final deterministicPath = firstMaster!.masterFitsPath!;
      // The native write produced a real file on the deterministic path.
      expect(await File(deterministicPath).exists(), isTrue);

      final mastersBefore = await mastersDao.getAll();

      // Re-integrate the SAME accepted population (no new subs). The seam
      // re-writes the master FITS to the SAME deterministic path, then
      // supersession runs. Idempotent: captured_count stays 2 (SET, not
      // 2+2=4); the prior master ROW is superseded with no orphan; and the
      // freshly-written FITS on the shared path is NOT deleted.
      await service.integratePanels(
        projectId,
        settings: IntegrationSettings.defaults,
        outputFitsPathBuilder: panelBase,
      );
      panels = await panelsDao.getForProject(projectId);
      expect(
        panels.single.capturedCount,
        2,
        reason:
            'captured_count must be SET to the accepted population, '
            'not accumulated to 4 on a re-run',
      );

      // The superseded master row is gone, not orphaned alongside the new one:
      // the total master count did not grow.
      final mastersAfter = await mastersDao.getAll();
      expect(
        mastersAfter.length,
        mastersBefore.length,
        reason: 're-integration must supersede the old master, not orphan it',
      );
      expect(
        await mastersDao.getById(firstMasterId),
        isNull,
        reason: 'the previous master row must be deleted on re-integration',
      );

      // The panel points at a fresh, live master.
      final newMasterId = panels.single.integratedMasterId!;
      expect(newMasterId, isNot(firstMasterId));
      final newMaster = await mastersDao.getById(newMasterId);
      expect(newMaster, isNotNull);

      // GUARD (findings #1/#3): the new master's FITS — written to the SAME
      // deterministic path the prior master used — MUST still exist. The
      // previous id-only supersession deleted it; the path-aware fix preserves
      // it.
      expect(
        newMaster!.masterFitsPath,
        deterministicPath,
        reason:
            'the re-integrated master uses the same durable '
            'deterministic path as the prior master',
      );
      expect(
        await File(deterministicPath).exists(),
        isTrue,
        reason:
            "the freshly-written master FITS on the shared path must "
            "SURVIVE supersession — it is the live file, not an orphan",
      );
    });

    test('after a same-path re-integration the panel can still be stitched — the '
        'preserved master FITS is on disk, not a dead path', () async {
      // End-to-end guard (findings #1/#3/#4): the failure class the WCS gate was
      // added to prevent is "one panel hands the native stitcher a path to a
      // missing file and aborts the whole mosaic". Prove a re-integrated 2-panel
      // mosaic still stitches: both panels' freshly-written masters survive on
      // their durable deterministic paths.
      seam.writeMasterFiles = true;
      final tempDir = await Directory.systemTemp.createTemp(
        'skotiq_mosaic_reint2_',
      );
      addTearDown(() async {
        if (await tempDir.exists()) await tempDir.delete(recursive: true);
      });

      final p0 = await seedTarget('Reint Stitch P0');
      final p1 = await seedTarget('Reint Stitch P1');
      await seedSub(targetId: p0, path: '/rs/p0a.fits');
      await seedSub(targetId: p0, path: '/rs/p0b.fits');
      await seedSub(targetId: p1, path: '/rs/p1a.fits');
      await seedSub(targetId: p1, path: '/rs/p1b.fits');

      final projectId = await service.createProject(
        name: 'Reint Stitch 1x2',
        rows: 1,
        cols: 2,
        centerRa: 0.7,
        centerDec: 41.0,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (i) => i == 0 ? p0 : p1,
      );

      String panelBase(MosaicProjectPanel panel) =>
          '${tempDir.path}/panel_${panel.panelIndex}.fits';

      // Integrate, then RE-integrate (same path) so supersession runs on both
      // panels.
      for (var pass = 0; pass < 2; pass++) {
        await service.integratePanels(
          projectId,
          settings: IntegrationSettings.defaults,
          outputFitsPathBuilder: panelBase,
        );
      }

      // Every panel's linked master FITS still exists on disk.
      final panels = await panelsDao.getForProject(projectId);
      for (final panel in panels) {
        final master = await mastersDao.getById(panel.integratedMasterId!);
        expect(
          await File(master!.masterFitsPath!).exists(),
          isTrue,
          reason:
              'panel ${panel.panelIndex} master FITS must survive '
              're-integration so the stitch is not poisoned',
        );
      }

      // The stitch goes through: both panels contribute (the file-existence
      // gate would have skipped a dead-path panel, dropping the count below 2).
      final outcome = await service.stitchProject(
        projectId,
        outputDirectory: tempDir.path,
        // Allow the WCS-less masters into the stitch via the header probe so
        // the file-existence gate is what this exercises.
        fitsHasWcs: (_) async => true,
      );
      expect(
        outcome.panelCount,
        2,
        reason:
            'both re-integrated panels must contribute — neither was '
            'skipped for a missing FITS',
      );
      expect(seam.stitchCalls, hasLength(1));
      expect((seam.stitchCalls.single['panels'] as List), hasLength(2));
    });
  });

  group('integratePanels distinct-target guard', () {
    test('throws when two panels share a capture target', () async {
      final shared = await seedTarget('Shared');
      await seedSub(targetId: shared, path: '/s/a.fits');
      final projectId = await service.createProject(
        name: 'Collide 1x2',
        rows: 1,
        cols: 2,
        centerRa: 0.7,
        centerDec: 41.0,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        // Both panels point at the SAME target — the collision the guard
        // exists to catch (they would fold each other's subs).
        panelTargetId: (_) => shared,
      );

      await expectLater(
        service.integratePanels(
          projectId,
          settings: IntegrationSettings.defaults,
          outputFitsPathBuilder: (panel) =>
              '/out/panel_${panel.panelIndex}.fits',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('startCapture', () {
    test(
      'launches the per-panel-target sequence and drives capturing state',
      () async {
        final t0 = await seedTarget('Cap P1');
        final t1 = await seedTarget('Cap P2');
        final projectId = await service.createProject(
          name: 'Cap 1x2',
          rows: 1,
          cols: 2,
          centerRa: 0.7,
          centerDec: 41.0,
          panelWidthArcmin: 30,
          panelHeightArcmin: 20,
          panelTargetId: (i) => i == 0 ? t0 : t1,
        );

        MosaicCaptureRequest? captured;
        final request = await service.startCapture(
          projectId,
          launcher: (req) async => captured = req,
        );

        // The launcher received a fully-populated, DISTINCT per-panel target map.
        expect(captured, isNotNull);
        expect(request.panelTargetIds, {0: t0, 1: t1});
        expect(request.panelTargetIds.values.toSet(), hasLength(2));

        // Project + non-integrated panels moved into capturing.
        final project = await projectsDao.getById(projectId);
        expect(project!.status, MosaicProjectStatus.capturing);
        final panels = await panelsDao.getForProject(projectId);
        expect(
          panels.every((p) => p.status == MosaicPanelStatus.capturing),
          isTrue,
        );
      },
    );

    test('refuses to launch when two panels share a capture target', () async {
      final shared = await seedTarget('Shared cap');
      final projectId = await service.createProject(
        name: 'Cap collide',
        rows: 1,
        cols: 2,
        centerRa: 0.7,
        centerDec: 41.0,
        panelWidthArcmin: 30,
        panelHeightArcmin: 20,
        panelTargetId: (_) => shared,
      );

      var launched = false;
      await expectLater(
        service.startCapture(projectId, launcher: (_) async => launched = true),
        throwsA(isA<StateError>()),
      );
      // The launcher was never invoked and the project was not flipped.
      expect(launched, isFalse);
      final project = await projectsDao.getById(projectId);
      expect(project!.status, isNot(MosaicProjectStatus.capturing));
    });
  });
}
